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
    return kind == WATCH_SOUND_WORKING || kind == WATCH_SOUND_FAILURE ? 1 : 2;
}

static inline uint16_t watch_sound_duration_ms(watch_sound_kind_t kind)
{
    return kind == WATCH_SOUND_WORKING ? 130 :
           kind == WATCH_SOUND_COMPLETION ? 300 :
           kind == WATCH_SOUND_FAILURE ? 310 : 380;
}

/* Short start, spaced high request, compact descending finish, held low fault. */
static inline alert_note_t watch_sound_note(watch_sound_kind_t kind, unsigned index)
{
    if (kind == WATCH_SOUND_WORKING)
        return (alert_note_t){0, 110, 1536, 10000};
    if (kind == WATCH_SOUND_FAILURE)
        return (alert_note_t){0, 280, 1280, 18000};
    if (kind == WATCH_SOUND_COMPLETION)
        return index == 0 ? (alert_note_t){0, 90, 2048, 15000} :
                            (alert_note_t){130, 140, 1536, 16000};
    return index == 0 ? (alert_note_t){0, 110, 2048, 18000} :
                        (alert_note_t){235, 125, 2048, 19000};
}
