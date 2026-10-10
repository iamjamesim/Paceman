/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include "paceman_state.h"

struct pbl_bt_device_internal;
struct pbl_bt_bonding;

/* The advertising helper copies 128-bit UUIDs verbatim; BLE uses little endian. */
#define PACEMAN_AD_UUID_BYTES \
  0xe1, 0x8e, 0xc9, 0xa2, 0xf3, 0x4c, 0xa5, 0xb7, 0x0d, 0x4f, 0x15, 0x1b, 0x01, 0x00, 0x51, 0x7f

typedef struct {
  PacemanRecord record;
  omarchy_activity_v1_t activity;
  bool storage_ready, connected, received, sources_received;
  uint8_t source_count;
  PacemanSource sources[PACEMAN_SOURCE_MAX];
} PacemanView;

void paceman_service_early_init(void);
void paceman_service_register(void);
bool paceman_service_pairing_allowed(void);
bool paceman_service_bond_write_allowed(const struct pbl_bt_device_internal *device);
void paceman_service_bond_saved(const struct pbl_bt_bonding *bonding, bool saved);
void paceman_service_bond_removed(const struct pbl_bt_device_internal *device);
/* Physical watch UI only; never exposed over GATT. Keeps the stable watch ID. */
bool paceman_service_reset_pairing(void);
void paceman_service_get_view(PacemanView *view);
void paceman_service_get_sessions(const uint8_t source_id[16], PacemanSessionView *view);
void paceman_service_notification_hint(const struct pbl_bt_device_internal *device, uint32_t uid,
                                       const uint8_t *app_id, size_t length);

/* Session handoff is metadata only; the phone owns destination resolution. */
typedef enum {
  PacemanHandoffNone, PacemanHandoffReady, PacemanHandoffNotification,
  PacemanHandoffOpenPhone, PacemanHandoffUnavailable,
  PacemanHandoffSending, PacemanHandoffOffline
} PacemanHandoffStatus;
void paceman_service_continue_on_phone(const uint8_t source_id[16], const uint8_t session_id[16]);
PacemanHandoffStatus paceman_service_handoff_status(void);
