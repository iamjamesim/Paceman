/* SPDX-License-Identifier: Apache-2.0 */
#include "paceman_storage.h"

#include <pbl/crc/crc.h>
#include <pbl/services/filesystem/pfs.h>
#include <pbl/services/settings/settings_file.h>

static const char s_filename[] = "paceman-owner";
static const char s_id_filename[] = "paceman-id";
static const uint8_t s_key = 1;
enum {
  RECORD_SIZE = 148,
  CRC_OFFSET = 144
};

PacemanStorage paceman_storage_load(PacemanRecord *record) {
  int fd = pfs_open(s_id_filename, OP_FLAG_READ, FILE_TYPE_STATIC, 0);
  if (fd < 0) {
    if (fd != E_DOES_NOT_EXIST)
      return PacemanStorageError;
    fd = pfs_open(s_filename, OP_FLAG_READ, FILE_TYPE_STATIC, 0);
    if (fd >= 0)
      pfs_close(fd);
    return fd == E_DOES_NOT_EXIST ? PacemanStorageMissing : PacemanStorageError;
  }
  uint8_t identity[20];
  bool valid = pfs_get_file_size(fd) == sizeof(identity) &&
               pfs_read(fd, identity, sizeof(identity)) == sizeof(identity);
  valid = pfs_close(fd) == S_SUCCESS && valid;
  if (!valid || pbl_crc32(0, identity, sizeof(identity)) != PBL_CRC32_RESIDUE)
    return PacemanStorageError;
  /* The immutable ID prevents a missing/recreated owner file reopening enrollment. */
  fd = pfs_open(s_filename, OP_FLAG_READ, FILE_TYPE_STATIC, 0);
  if (fd < 0)
    return PacemanStorageError;
  pfs_close(fd);
  SettingsFile file;
  if (settings_file_open(&file, s_filename, 1024) != S_SUCCESS)
    return PacemanStorageError;
  uint8_t bytes[RECORD_SIZE];
  valid = settings_file_get_len(&file, &s_key, sizeof(s_key)) == sizeof(bytes) &&
          settings_file_get(&file, &s_key, sizeof(s_key), bytes, sizeof(bytes)) == S_SUCCESS;
  settings_file_close(&file);
  if (!valid || memcmp(bytes, "PM01", 4) || bytes[21] > 1 || memcmp(identity, bytes + 5, 16) ||
      pbl_crc32(0, bytes, sizeof(bytes)) != PBL_CRC32_RESIDUE)
    return PacemanStorageError;
  *record = (PacemanRecord){
    .version = bytes[4],
    .owned = bytes[21],
    .owner_peer.type = bytes[22],
    .profile_size = bytes[29]
  };
  memcpy(record->device_id, bytes + 5, 16);
  memcpy(record->owner_peer.address, bytes + 23, 6);
  memcpy(record->profile, bytes + 30, PACEMAN_PROFILE_MAX);
  return paceman_record_valid(record) ? PacemanStorageLoaded : PacemanStorageError;
}

bool paceman_storage_save(const PacemanRecord *record, bool create) {
  uint8_t bytes[RECORD_SIZE] = {'P', 'M', '0', '1', record->version};
  memcpy(bytes + 5, record->device_id, 16);
  bytes[21] = record->owned;
  bytes[22] = record->owner_peer.type;
  memcpy(bytes + 23, record->owner_peer.address, 6);
  bytes[29] = record->profile_size;
  memcpy(bytes + 30, record->profile, PACEMAN_PROFILE_MAX);
  uint32_t crc = pbl_crc32(0, bytes, CRC_OFFSET);
  for (size_t i = 0; i < 4; ++i)
    bytes[CRC_OFFSET + i] = crc >> (8 * i);
  if (!create) {
    PacemanRecord old;
    if (paceman_storage_load(&old) != PacemanStorageLoaded)
      return false;
  }
  SettingsFile file;
  if (settings_file_open(&file, s_filename, 1024) != S_SUCCESS)
    return false;
  bool saved = settings_file_set(&file, &s_key, sizeof(s_key), bytes, sizeof(bytes)) == S_SUCCESS;
  settings_file_close(&file);
  if (!saved)
    return false;
  if (create) {
    uint8_t identity[20];
    memcpy(identity, record->device_id, 16);
    crc = pbl_crc32(0, identity, 16);
    for (size_t i = 0; i < 4; ++i)
      identity[16 + i] = crc >> (8 * i);
    int fd = pfs_open(s_id_filename, OP_FLAG_WRITE, FILE_TYPE_STATIC, sizeof(identity));
    if (fd < 0)
      return false;
    saved = pfs_write(fd, identity, sizeof(identity)) == sizeof(identity);
    saved = pfs_close(fd) == S_SUCCESS && saved;
    if (!saved)
      return false;
  }
  PacemanRecord verify;
  return paceman_storage_load(&verify) == PacemanStorageLoaded &&
         memcmp(verify.device_id, record->device_id, 16) == 0 && verify.owned == record->owned &&
         verify.profile_size == record->profile_size &&
         memcmp(&verify.owner_peer, &record->owner_peer, sizeof(verify.owner_peer)) == 0 &&
         memcmp(verify.profile, record->profile, PACEMAN_PROFILE_MAX) == 0;
}
