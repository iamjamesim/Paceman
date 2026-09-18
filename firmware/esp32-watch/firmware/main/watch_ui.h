#pragma once

#include <stdint.h>

#include "esp_err.h"
#include "watch_profile.h"

esp_err_t watch_ui_start(void);
void watch_ui_show_pairing(uint32_t passkey);
void watch_ui_show_time_unavailable(void);
void watch_ui_show_face(void);
void watch_ui_show_error(const char *message);
void watch_ui_apply_time(int64_t unix_time, int16_t utc_offset_minutes, uint8_t hour_cycle);
void watch_ui_apply_profile_v2(const omarchy_profile_v2_t *profile);
void watch_ui_apply_profile_v3(const omarchy_profile_v3_t *profile);
void watch_ui_apply_profile_v5(const omarchy_profile_v5_t *profile);
void watch_ui_apply_profile_v4(const omarchy_profile_v4_t *profile);
void watch_ui_apply_activity(uint8_t state, bool alert, bool sound);
void watch_ui_set_connected(bool connected);
