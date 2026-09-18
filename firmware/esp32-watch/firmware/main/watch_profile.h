#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum {
    OMARCHY_PROTOCOL_VERSION_MIN = 1,
    OMARCHY_PROTOCOL_VERSION = 5,
    OMARCHY_PROFILE_KIND = 1,
    OMARCHY_FIRMWARE_VERSION_MAJOR = 0,
    OMARCHY_FIRMWARE_VERSION_MINOR = 6,
    OMARCHY_FIRMWARE_VERSION_PATCH = 1,
    OMARCHY_MIN_UTC_OFFSET_MINUTES = -12 * 60,
    OMARCHY_MAX_UTC_OFFSET_MINUTES = 14 * 60,
    OMARCHY_CAP_TIME_SYNC = 1 << 0,
    OMARCHY_CAP_HOUR_CYCLE = 1 << 1,
    OMARCHY_CAP_RTC = 1 << 2,
    OMARCHY_CAP_THEME = 1 << 3,
    OMARCHY_CAP_WEATHER = 1 << 4,
    OMARCHY_CAP_DISPLAY_BRIGHTNESS = 1 << 5,
    OMARCHY_CAP_AGENT_ACTIVITY = 1 << 6,
    OMARCHY_CAP_COMPLETION_SOUND = 1 << 7,
    OMARCHY_CAP_ACTIVITY_FINISHED = 1 << 8,
    OMARCHY_PROFILE_WEATHER_VALID = 1 << 0,
    OMARCHY_PROFILE_WEATHER_FAHRENHEIT = 1 << 1,
    OMARCHY_PROFILE_WEATHER_NIGHT = 1 << 2,
    OMARCHY_PROFILE_DISPLAY_PREVIEW = 1 << 3,
};

typedef struct __attribute__((packed)) {
    uint8_t magic[2];
    uint8_t version;
    uint8_t kind;
    uint32_t revision;
    int64_t unix_time;
    int16_t utc_offset_minutes;
    uint8_t hour_cycle;
    uint8_t reserved;
    uint8_t owner_id[16];
} omarchy_profile_v1_t;

typedef struct __attribute__((packed)) {
    uint8_t magic[2];
    uint8_t version;
    uint8_t kind;
    uint32_t revision;
    int64_t unix_time;
    int16_t utc_offset_minutes;
    uint8_t hour_cycle;
    uint8_t flags;
    uint8_t owner_id[16];
    uint8_t background_rgb[3];
    uint8_t foreground_rgb[3];
    int64_t weather_updated_at;
    int16_t temperature;
    int16_t high_temperature;
    int16_t low_temperature;
    uint8_t weather_code;
    char location[24];
} omarchy_profile_v2_t;

typedef struct __attribute__((packed)) {
    uint8_t magic[2];
    uint8_t version;
    uint8_t kind;
    uint32_t revision;
    int64_t unix_time;
    int16_t utc_offset_minutes;
    uint8_t hour_cycle;
    uint8_t flags;
    uint8_t owner_id[16];
    uint8_t background_rgb[3];
    uint8_t foreground_rgb[3];
    int64_t weather_updated_at;
    int16_t temperature;
    int16_t high_temperature;
    int16_t low_temperature;
    uint8_t weather_code;
    char location[24];
    uint8_t accent_rgb[3];
    uint8_t brightness_percent;
} omarchy_profile_v3_t;

/* v4 retains the complete v3 prefix. 255 means allowance unavailable.
 * Window: 1 = weekly, 2 = session. Provider is Codex for this version. */
typedef struct __attribute__((packed)) {
    omarchy_profile_v3_t base;
    uint8_t allowance_remaining;
    uint8_t allowance_window;
    int64_t allowance_updated_at;
    int64_t allowance_resets_at;
} omarchy_profile_v4_t;

/* v5 preserves the v4 prefix and carries the forecast's local midnight.
 * Timestamps remain source times even when a cached snapshot is retransmitted. */
typedef struct __attribute__((packed)) {
    omarchy_profile_v4_t base;
    int64_t weather_daily_expires_at;
} omarchy_profile_v5_t;

enum { OMARCHY_DATA_FRESH_SECONDS = 1800, OMARCHY_WEATHER_CURRENT_SECONDS = 10800 };

static inline bool omarchy_data_stale(int64_t updated, int64_t now)
{
    return updated > 0 && updated <= now && now - updated > OMARCHY_DATA_FRESH_SECONDS;
}

static inline bool omarchy_weather_current(int64_t updated, int64_t now)
{
    return updated > 0 && updated <= now && now - updated <= OMARCHY_WEATHER_CURRENT_SECONDS;
}

static inline int omarchy_allowance_remaining(uint8_t remaining, int64_t updated,
                                              int64_t resets, int64_t now)
{
    return remaining <= 100 && updated > 0 && updated <= now && resets > now
        ? remaining : -1;
}

typedef struct __attribute__((packed)) {
    uint8_t magic[2];
    uint8_t protocol_min;
    uint8_t protocol_max;
    uint8_t flags;
    uint8_t reserved[3];
    uint8_t device_id[16];
    uint32_t capabilities;
    uint8_t firmware_major;
    uint8_t firmware_minor;
    uint8_t firmware_patch;
    uint8_t reserved_end;
} omarchy_identity_v1_t;

enum {
    OMARCHY_ACTIVITY_VERSION = 1,
    OMARCHY_ACTIVITY_NONE = 0,
    OMARCHY_ACTIVITY_WORKING = 1,
    OMARCHY_ACTIVITY_ATTENTION = 2,
    OMARCHY_ACTIVITY_FINISHED = 3,
    OMARCHY_ACTIVITY_ALERT = 1 << 0,
    OMARCHY_ACTIVITY_SOUND = 1 << 1,
};

/*
 * Desktop-to-watch activity snapshot. The watch returns the same shape when
 * read or notified, with acknowledged_revision set to the newest snapshot the
 * wearer explicitly cleared.
 */
typedef struct __attribute__((packed)) {
    uint8_t magic[2];
    uint8_t version;
    uint8_t state;
    uint8_t flags;
    uint8_t reserved;
    uint32_t revision;
    uint32_t acknowledged_revision;
} omarchy_activity_v1_t;

_Static_assert(sizeof(omarchy_profile_v1_t) == 36, "profile wire size changed");
_Static_assert(sizeof(omarchy_profile_v2_t) == 81, "v2 profile wire size changed");
_Static_assert(sizeof(omarchy_profile_v3_t) == 85, "v3 profile wire size changed");
_Static_assert(sizeof(omarchy_profile_v4_t) == 103, "v4 profile wire size changed");
_Static_assert(sizeof(omarchy_profile_v5_t) == 111, "v5 profile wire size changed");
_Static_assert(sizeof(omarchy_identity_v1_t) == 32, "identity wire size changed");
_Static_assert(sizeof(omarchy_activity_v1_t) == 14, "activity wire size changed");

static inline bool omarchy_activity_v1_is_valid(const omarchy_activity_v1_t *activity)
{
    return activity != NULL && activity->magic[0] == 'O' &&
           activity->magic[1] == 'A' &&
           activity->version == OMARCHY_ACTIVITY_VERSION &&
           activity->state <= OMARCHY_ACTIVITY_FINISHED &&
           (activity->flags & ~(OMARCHY_ACTIVITY_ALERT | OMARCHY_ACTIVITY_SOUND)) == 0 &&
           activity->revision != 0;
}

static inline bool omarchy_profile_v1_is_valid(const omarchy_profile_v1_t *profile)
{
    /* The RTC driver stores a two-digit year relative to 1970. */
    const int64_t earliest_supported_time = INT64_C(1704067200);  /* 2024-01-01 */
    const int64_t latest_supported_time = INT64_C(3155759999);   /* 2069-12-31 */

    return profile != NULL && profile->magic[0] == 'O' && profile->magic[1] == 'W' &&
           profile->version == 1 &&
           profile->kind == OMARCHY_PROFILE_KIND &&
           profile->unix_time >= earliest_supported_time &&
           profile->unix_time <= latest_supported_time &&
           profile->utc_offset_minutes >= OMARCHY_MIN_UTC_OFFSET_MINUTES &&
           profile->utc_offset_minutes <= OMARCHY_MAX_UTC_OFFSET_MINUTES &&
           (profile->hour_cycle == 12 || profile->hour_cycle == 24);
}

static inline bool omarchy_profile_v2_is_valid(const omarchy_profile_v2_t *profile)
{
    const int64_t earliest_supported_time = INT64_C(1704067200);  /* 2024-01-01 */
    const int64_t latest_supported_time = INT64_C(3155759999);   /* 2069-12-31 */
    const bool weather_valid = profile != NULL &&
                               (profile->flags & OMARCHY_PROFILE_WEATHER_VALID) != 0;

    return profile != NULL && profile->magic[0] == 'O' && profile->magic[1] == 'W' &&
           profile->version == 2 &&
           profile->kind == OMARCHY_PROFILE_KIND &&
           profile->unix_time >= earliest_supported_time &&
           profile->unix_time <= latest_supported_time &&
           profile->utc_offset_minutes >= OMARCHY_MIN_UTC_OFFSET_MINUTES &&
           profile->utc_offset_minutes <= OMARCHY_MAX_UTC_OFFSET_MINUTES &&
           (profile->hour_cycle == 12 || profile->hour_cycle == 24) &&
           (!weather_valid ||
            (profile->weather_updated_at >= earliest_supported_time &&
             profile->weather_updated_at <= latest_supported_time &&
             profile->temperature >= -99 && profile->temperature <= 199 &&
             profile->high_temperature >= -99 && profile->high_temperature <= 199 &&
             profile->low_temperature >= -99 && profile->low_temperature <= 199 &&
             profile->weather_code <= 99 &&
             memchr(profile->location, '\0', sizeof(profile->location)) != NULL));
}

static inline bool omarchy_profile_v3_is_valid(const omarchy_profile_v3_t *profile)
{
    const int64_t earliest_supported_time = INT64_C(1704067200);  /* 2024-01-01 */
    const int64_t latest_supported_time = INT64_C(3155759999);   /* 2069-12-31 */
    const bool weather_valid = profile != NULL &&
                               (profile->flags & OMARCHY_PROFILE_WEATHER_VALID) != 0;

    return profile != NULL && profile->magic[0] == 'O' && profile->magic[1] == 'W' &&
           profile->version == 3 &&
           profile->kind == OMARCHY_PROFILE_KIND &&
           profile->unix_time >= earliest_supported_time &&
           profile->unix_time <= latest_supported_time &&
           profile->utc_offset_minutes >= OMARCHY_MIN_UTC_OFFSET_MINUTES &&
           profile->utc_offset_minutes <= OMARCHY_MAX_UTC_OFFSET_MINUTES &&
           (profile->hour_cycle == 12 || profile->hour_cycle == 24) &&
           profile->brightness_percent >= 20 && profile->brightness_percent <= 100 &&
           (!weather_valid ||
            (profile->weather_updated_at >= earliest_supported_time &&
             profile->weather_updated_at <= latest_supported_time &&
             profile->temperature >= -99 && profile->temperature <= 199 &&
             profile->high_temperature >= -99 && profile->high_temperature <= 199 &&
             profile->low_temperature >= -99 && profile->low_temperature <= 199 &&
             profile->weather_code <= 99 &&
             memchr(profile->location, '\0', sizeof(profile->location)) != NULL));
}

static inline bool omarchy_profile_v4_is_valid(const omarchy_profile_v4_t *profile)
{
    if (profile == NULL || profile->base.version != 4) return false;
    omarchy_profile_v3_t base = profile->base;
    base.version = 3;
    return omarchy_profile_v3_is_valid(&base) &&
        ((profile->allowance_remaining == 255 && profile->allowance_window == 0 &&
          profile->allowance_updated_at == 0 && profile->allowance_resets_at == 0) ||
         (profile->allowance_remaining <= 100 &&
          (profile->allowance_window == 1 || profile->allowance_window == 2) &&
          profile->allowance_updated_at >= INT64_C(1704067200) &&
          profile->allowance_updated_at <= base.unix_time &&
          profile->allowance_resets_at > base.unix_time &&
          profile->allowance_resets_at <= INT64_C(3155759999)));
}

static inline bool omarchy_profile_v5_is_valid(const omarchy_profile_v5_t *profile)
{
    if (!profile || profile->base.base.version != 5) return false;
    omarchy_profile_v4_t base = profile->base;
    base.base.version = 4;
    base.allowance_remaining = 255;
    base.allowance_window = 0;
    base.allowance_updated_at = base.allowance_resets_at = 0;
    const omarchy_profile_v4_t *p = &profile->base;
    const bool allowance_valid =
        (p->allowance_remaining == 255 && p->allowance_window == 0 &&
         p->allowance_updated_at == 0 && p->allowance_resets_at == 0) ||
        (p->allowance_remaining <= 100 && (p->allowance_window == 1 || p->allowance_window == 2) &&
         p->allowance_updated_at >= INT64_C(1704067200) &&
         p->allowance_updated_at <= p->base.unix_time &&
         p->allowance_resets_at > p->allowance_updated_at &&
         p->allowance_resets_at <= INT64_C(3155759999));
    const int64_t end = profile->weather_daily_expires_at;
    return omarchy_profile_v4_is_valid(&base) && allowance_valid &&
        (end == 0 || (end >= INT64_C(1704067200) && end <= INT64_C(3155759999))) &&
        (!(p->base.flags & OMARCHY_PROFILE_WEATHER_VALID) ||
         p->base.weather_updated_at <= p->base.unix_time);
}
