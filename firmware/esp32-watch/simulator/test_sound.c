#include <assert.h>
#include <stdio.h>
#include "watch_sound_pattern.h"

int main(void)
{
    alert_note_t first = watch_sound_note(WATCH_SOUND_ATTENTION, 0);
    alert_note_t second = watch_sound_note(WATCH_SOUND_ATTENTION, 1);
    assert(first.frequency == 2048 && second.frequency == 2048);
    assert(first.start_ms == 0 && first.duration_ms == 110 && first.amplitude == 18000);
    assert(second.start_ms == 235 && second.duration_ms == 125 && second.amplitude == 19000);
    assert(watch_sound_note_count(WATCH_SOUND_WORKING) == 1);
    assert(watch_sound_duration_ms(WATCH_SOUND_WORKING) == 130);
    alert_note_t working = watch_sound_note(WATCH_SOUND_WORKING, 0);
    assert(working.start_ms == 0 && working.duration_ms == 110);
    assert(working.frequency == 1536 && working.amplitude < first.amplitude);
    assert(watch_sound_note_count(WATCH_SOUND_COMPLETION) == 2);
    assert(watch_sound_duration_ms(WATCH_SOUND_COMPLETION) == 300);
    assert(watch_sound_note_count(WATCH_SOUND_FAILURE) == 1);
    assert(watch_sound_duration_ms(WATCH_SOUND_FAILURE) == 310);
    alert_note_t finish_first = watch_sound_note(WATCH_SOUND_COMPLETION, 0);
    alert_note_t finish_second = watch_sound_note(WATCH_SOUND_COMPLETION, 1);
    assert(finish_first.frequency == 2048 && finish_second.frequency == 1536);
    assert(finish_first.duration_ms == 90 && finish_second.start_ms == 130);
    assert(finish_second.duration_ms == 140 && finish_second.start_ms + finish_second.duration_ms <= 300);
    assert(finish_first.amplitude < first.amplitude && finish_second.amplitude < second.amplitude);
    alert_note_t failure = watch_sound_note(WATCH_SOUND_FAILURE, 0);
    assert(failure.start_ms == 0 && failure.duration_ms == 280);
    assert(failure.frequency == 1280 && failure.amplitude == first.amplitude);
    for (unsigned i = 0; i < 2; ++i) {
        alert_note_t attention = watch_sound_note(WATCH_SOUND_ATTENTION, i);
        assert(attention.frequency == 2048);
        assert(attention.start_ms == (i == 0 ? 0 : 235));
        assert(attention.duration_ms == (i == 0 ? 110 : 125));
    }
    puts("Sound patterns: quiet start, spaced request, compact finish, held fault");
}
