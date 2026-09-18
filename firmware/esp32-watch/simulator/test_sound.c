#include <assert.h>
#include <stdio.h>
#include "watch_sound_pattern.h"

int main(void)
{
    alert_note_t first = watch_sound_note(true, 0);
    alert_note_t second = watch_sound_note(true, 1);
    assert(first.frequency == 2048 && second.frequency == 2048);
    assert(first.start_ms == 0 && first.duration_ms == 110 && first.amplitude == 18000);
    assert(second.start_ms == 235 && second.duration_ms == 125 && second.amplitude == 19000);
    for (unsigned i = 0; i < 2; ++i) {
        alert_note_t attention = watch_sound_note(true, i);
        alert_note_t done = watch_sound_note(false, i);
        assert(attention.start_ms == done.start_ms);
        assert(attention.duration_ms == done.duration_ms);
        assert(attention.amplitude == done.amplitude);
        assert(done.start_ms + done.duration_ms <= 380);
        assert(done.frequency == (i == 0 ? 2048 : 1536));
    }
    puts("Sound patterns: legacy attention preserved, completion descends");
}
