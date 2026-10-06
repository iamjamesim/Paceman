#include <assert.h>
#include <stdio.h>
#include "watch_profile.h"

int main(int argc, char **argv)
{
    omarchy_activity_v1_t activity = {
        .magic = {'O', 'A'}, .version = OMARCHY_ACTIVITY_VERSION,
        .state = OMARCHY_ACTIVITY_FAILED, .revision = 1
    };
    assert(omarchy_activity_v1_is_valid(&activity));
    activity.state = OMARCHY_ACTIVITY_WORKING;
    activity.flags = OMARCHY_ACTIVITY_SOUND;
    omarchy_activity_cue_t cue = omarchy_activity_cue(&activity, 0, 0);
    assert(cue.sound && !cue.alert);
    cue = omarchy_activity_cue(&activity, 1, 0);
    assert(!cue.sound && !cue.alert);  /* repeat of a cued revision */
    activity.revision = 2;
    activity.state = OMARCHY_ACTIVITY_FAILED;
    activity.flags = OMARCHY_ACTIVITY_SOUND | OMARCHY_ACTIVITY_ALERT;
    cue = omarchy_activity_cue(&activity, 1, 0);
    assert(cue.sound && cue.alert);
    activity.flags = OMARCHY_ACTIVITY_SOUND;
    cue = omarchy_activity_cue(&activity, 1, 0);
    assert(!cue.sound && !cue.alert);  /* no sound-only failure */
    activity.flags = OMARCHY_ACTIVITY_SOUND | OMARCHY_ACTIVITY_ALERT;
    cue = omarchy_activity_cue(&activity, 1, 2);
    assert(!cue.sound && !cue.alert);  /* acknowledged revision */
    activity.state = OMARCHY_ACTIVITY_FAILED + 1;
    assert(!omarchy_activity_v1_is_valid(&activity));
    /* Revision 41 arrived while revision 40 was displayed: a tap cannot dismiss 41. */
    activity.revision = 41;
    activity.state = OMARCHY_ACTIVITY_ATTENTION;
    assert(!omarchy_activity_can_acknowledge(&activity, 40));
    assert(!omarchy_activity_can_acknowledge(&activity, 0));
    assert(!omarchy_activity_can_acknowledge(NULL, 41));
    const uint8_t dismissible[] = {OMARCHY_ACTIVITY_ATTENTION,
        OMARCHY_ACTIVITY_FINISHED, OMARCHY_ACTIVITY_FAILED};
    for (size_t index = 0; index < sizeof(dismissible); ++index) {
        activity.state = dismissible[index];
        assert(omarchy_activity_can_acknowledge(&activity, 41));
    }
    activity.state = OMARCHY_ACTIVITY_WORKING;
    assert(!omarchy_activity_can_acknowledge(&activity, 41));
    activity.state = OMARCHY_ACTIVITY_NONE;
    assert(!omarchy_activity_can_acknowledge(&activity, 41));
    omarchy_profile_v4_t p = {0};
    if (argc == 2) {
        omarchy_profile_v5_t incoming = {0};
        FILE *input = fopen(argv[1], "rb");
        assert(input != NULL);
        size_t size = fread(&incoming, 1, sizeof(incoming), input);
        assert(fgetc(input) == EOF);
        fclose(input);
        assert((size == sizeof(incoming) && omarchy_profile_v5_is_valid(&incoming)) ||
               (size == sizeof(p) && omarchy_profile_v4_is_valid(&incoming.base)));
    }
    p.base = (omarchy_profile_v3_t){.magic = {'O', 'W'}, .version = 4,
        .kind = 1, .unix_time = 1800000000, .hour_cycle = 24, .brightness_percent = 55};
    p.allowance_remaining = 79;
    p.allowance_window = 1;
    p.allowance_updated_at = p.base.unix_time;
    p.allowance_resets_at = p.base.unix_time + 86400;
    assert(omarchy_profile_v4_is_valid(&p));
    assert(!omarchy_profile_v3_is_valid(&p.base));
    p.base.version = 3;
    assert(omarchy_profile_v3_is_valid(&p.base));
    assert(!omarchy_profile_v4_is_valid(&p));
    p.base.version = 4;
    p.allowance_remaining = 101;
    assert(!omarchy_profile_v4_is_valid(&p));
    p.allowance_remaining = 255;
    assert(!omarchy_profile_v4_is_valid(&p));
    p.allowance_window = 0;
    p.allowance_updated_at = p.allowance_resets_at = 0;
    assert(omarchy_profile_v4_is_valid(&p));
    assert(omarchy_allowance_remaining(79, 1800000000, 1800100000, 1800001800) == 79);
    assert(omarchy_allowance_remaining(79, 1800000000, 1800100000, 1800001801) == 79);
    assert(omarchy_allowance_remaining(79, 1800000001, 1800100000, 1800000000) == -1);
    assert(omarchy_allowance_remaining(79, 1800000000, 1800000010, 1800000010) == -1);
    assert(omarchy_allowance_remaining(0, 1800000000, 1800100000, 1800000000) == 0);
    assert(!omarchy_data_stale(1800000000, 1800001800));
    assert(omarchy_data_stale(1800000000, 1800001801));
    assert(omarchy_weather_current(1800000000, 1800010800));
    assert(!omarchy_weather_current(1800000000, 1800010801));
    assert(!omarchy_weather_current(1800000001, 1800000000));
    omarchy_profile_v5_t v5 = {.base = p, .weather_daily_expires_at = 1800086400};
    v5.base.base.version = 5;
    v5.base.allowance_remaining = 54;
    v5.base.allowance_window = 1;
    v5.base.allowance_updated_at = 1799990000;
    v5.base.allowance_resets_at = 1799999999;  /* expired, awaiting a new reading */
    assert(omarchy_profile_v5_is_valid(&v5));
    assert(!omarchy_profile_v4_is_valid(&v5.base));
    v5.base.base.version = 4;
    assert(!omarchy_profile_v4_is_valid(&v5.base));  /* old firmware rejects expired data */
    v5.base.base.version = 5;
    v5.base.allowance_resets_at = v5.base.allowance_updated_at;
    assert(!omarchy_profile_v5_is_valid(&v5));
    puts("Profile compatibility and allowance expiry checks passed");
    return 0;
}
