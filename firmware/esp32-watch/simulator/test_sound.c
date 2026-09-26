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
    for (unsigned i = 0; i < 2; ++i) {
        alert_note_t attention = watch_sound_note(WATCH_SOUND_ATTENTION, i);
        alert_note_t done = watch_sound_note(WATCH_SOUND_COMPLETION, i);
        alert_note_t failure = watch_sound_note(WATCH_SOUND_FAILURE, i);
        assert(attention.start_ms == done.start_ms);
        assert(attention.duration_ms == done.duration_ms);
        assert(attention.amplitude == done.amplitude);
        assert(done.start_ms + done.duration_ms <= 380);
        assert(done.frequency == (i == 0 ? 2048 : 1536));
        assert(failure.start_ms == attention.start_ms);
        assert(failure.duration_ms == attention.duration_ms);
        assert(failure.frequency == 1280);
    }
    puts("Sound patterns: quiet start, existing attention/completion, lower failure");
}
