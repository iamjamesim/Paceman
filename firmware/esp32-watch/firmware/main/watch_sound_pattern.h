#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint16_t start_ms;
    uint16_t duration_ms;
    uint16_t frequency;
    uint16_t amplitude;
} alert_note_t;

typedef enum {
    WATCH_SOUND_WORKING,
    WATCH_SOUND_ATTENTION,
    WATCH_SOUND_COMPLETION,
    WATCH_SOUND_FAILURE,
} watch_sound_kind_t;

static inline unsigned watch_sound_note_count(watch_sound_kind_t kind)
{
    return kind == WATCH_SOUND_WORKING ? 1 : 2;
}

static inline uint16_t watch_sound_duration_ms(watch_sound_kind_t kind)
{
    return kind == WATCH_SOUND_WORKING ? 130 : 380;
}

/* Keep the existing attention and completion tones. New work gets one softer
 * note; failure has the attention rhythm at a distinctly lower pitch. */
static inline alert_note_t watch_sound_note(watch_sound_kind_t kind, unsigned index)
{
    if (kind == WATCH_SOUND_WORKING)
        return (alert_note_t){0, 110, 1536, 10000};
    if (index == 0)
        return (alert_note_t){0, 110, kind == WATCH_SOUND_FAILURE ? 1280 : 2048, 18000};
    const uint16_t second = kind == WATCH_SOUND_ATTENTION ? 2048 :
                            kind == WATCH_SOUND_COMPLETION ? 1536 : 1280;
    return (alert_note_t){235, 125, second, 19000};
}
