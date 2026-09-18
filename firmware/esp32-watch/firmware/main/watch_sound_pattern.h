#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint16_t start_ms;
    uint16_t duration_ms;
    uint16_t frequency;
    uint16_t amplitude;
} alert_note_t;

/* Preserve the existing retro ti-ti for attention. Completion changes only
 * the second pitch: a descending perfect fourth, not a sliding power-off tone.
 * Both retain the same timing, timbre, gain, and total playback duration. */
static inline alert_note_t watch_sound_note(bool attention, unsigned index)
{
    if (index == 0)
        return (alert_note_t){0, 110, 2048, 18000};
    return (alert_note_t){235, 125, attention ? 2048 : 1536, 19000};
}
