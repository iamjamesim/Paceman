#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lvgl.h"
#include "watch_face_layout.h"
#include "watch_profile.h"
#include "watch_rim_geometry.h"
#include <time.h>

static void test_resource_colors(void)
{
    const watch_face_theme_t theme = {
        .background = {0, 0, 0}, .foreground = {200, 200, 200}, .accent = {255, 0, 100}
    };
    watch_face_layout_t layout;
    watch_face_layout_create(lv_screen_active(), &layout, &theme);
    const lv_color_t foreground = lv_color_make(200, 200, 200);
    const lv_color_t accent = lv_color_make(255, 0, 100);
    const int values[] = {-1, 0, 10, 19, 20, 21, 100, 255};
    for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
        const int value = values[i];
        const bool low = value >= 0 && value <= 20;
        for (int charging = 0; charging <= 1; ++charging) {
            for (int detail = 0; detail <= 1; ++detail) {
                watch_face_layout_set_battery(&layout, "󰂀", charging, value, "20%", detail);
                const lv_color_t expected = charging || low ? accent : foreground;
                if (!lv_color_eq(lv_obj_get_style_text_color(layout.battery, 0), expected) ||
                    !lv_color_eq(lv_obj_get_style_text_color(layout.battery_percentage, 0), expected) ||
                    lv_obj_has_flag(layout.battery_charge, LV_OBJ_FLAG_HIDDEN) != (!charging || detail)) {
                    fputs("Battery color/charging regression\n", stderr);
                    exit(1);
                }
            }
        }
        watch_face_layout_set_allowance(&layout, value, 1, 3600);
        if (!lv_color_eq(lv_obj_get_style_text_color(layout.allowance_title, 0), low ? accent : foreground) ||
            !lv_color_eq(lv_obj_get_style_text_color(layout.allowance_reset, 0), foreground)) {
            fputs("Allowance color regression\n", stderr);
            exit(1);
        }
    }
    /* Refresh transitions keep number geometry stable and clear stale markers. */
    const int64_t now = 1800000000;
    watch_face_layout_set_allowance(&layout, 54, 1, 86400);
    const int x = lv_obj_get_x(layout.allowance_title);
    watch_face_layout_allowance_age(&layout, 54, now-7200, now+86400, now, false);
    if (lv_obj_has_flag(layout.allowance_history, LV_OBJ_FLAG_HIDDEN) ||
        strcmp(lv_label_get_text(layout.allowance_title), "CODEX  54% LEFT") ||
        lv_obj_get_x(layout.allowance_title) != x) exit(1);
    watch_face_layout_set_allowance(&layout, 54, 1, 86400);
    watch_face_layout_allowance_age(&layout, 54, now, now+86400, now, false);
    if (!lv_obj_has_flag(layout.allowance_history, LV_OBJ_FLAG_HIDDEN) ||
        lv_obj_get_x(layout.allowance_title) != x) exit(1);
    watch_face_layout_weather_snapshot(&layout, "", "68°", "PARTLY\nCLOUDY",
        "H 72°  L 61°", "", now-14400, now+3600, now, false);
    if (strcmp(lv_label_get_text(layout.temperature), "--°") ||
        strcmp(lv_label_get_text(layout.range), "H 72°  L 61°")) exit(1);
    watch_face_layout_weather_snapshot(&layout, "", "68°", "PARTLY\nCLOUDY",
        "H 72°  L 61°", "", now-14400, now, now, false);
    if (strcmp(lv_label_get_text(layout.range), "H --°  L --°")) exit(1);
    watch_face_layout_weather_snapshot(&layout, "", "68°", "PARTLY\nCLOUDY",
        "H 72°  L 61°", "", now, now+86400, now, false);
    if (strcmp(lv_label_get_text(layout.temperature), "68°") ||
        !lv_obj_has_flag(layout.weather_history, LV_OBJ_FLAG_HIDDEN)) exit(1);
    watch_face_layout_set_allowance(&layout, 10, 1, 0);
    if (!lv_color_eq(lv_obj_get_style_text_color(layout.allowance_title, 0), foreground)) {
        fputs("Expired allowance highlighted as low\n", stderr);
        exit(1);
    }
}

static void flush_display(lv_display_t *display, const lv_area_t *area, uint8_t *pixels)
{
    LV_UNUSED(area);
    LV_UNUSED(pixels);
    lv_display_flush_ready(display);
}

static int write_ppm(const char *path, const lv_draw_buf_t *draw_buffer)
{
    FILE *output = fopen(path, "wb");
    if (output == NULL) {
        perror(path);
        return 1;
    }

    fprintf(output, "P6\n%d %d\n255\n", WATCH_FACE_WIDTH, WATCH_FACE_HEIGHT);
    const uint8_t *row = draw_buffer->data;
    for (int y = 0; y < WATCH_FACE_HEIGHT; ++y) {
        for (int x = 0; x < WATCH_FACE_WIDTH; ++x) {
            const uint16_t pixel = ((const uint16_t *)row)[x];
            const uint8_t rgb[] = {
                (uint8_t)((((pixel >> 11) & 0x1f) * 255 + 15) / 31),
                (uint8_t)((((pixel >> 5) & 0x3f) * 255 + 31) / 63),
                (uint8_t)(((pixel & 0x1f) * 255 + 15) / 31),
            };
            if (fwrite(rgb, sizeof(rgb), 1, output) != 1) {
                perror(path);
                fclose(output);
                return 1;
            }
        }
        row += draw_buffer->header.stride;
    }

    fclose(output);
    return 0;
}

static int parse_color(const char *text, uint8_t color[3])
{
    unsigned int red;
    unsigned int green;
    unsigned int blue;
    char trailing;
    if (text == NULL || strlen(text) != 7 || text[0] != '#' ||
        sscanf(text + 1, "%2x%2x%2x%c", &red, &green, &blue, &trailing) != 3) {
        return 1;
    }
    color[0] = (uint8_t)red;
    color[1] = (uint8_t)green;
    color[2] = (uint8_t)blue;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--corner-radius") == 0) {
        printf("%d\n", WATCH_SCREEN_CORNER_RADIUS);
        return 0;
    }
    const char *allowance = getenv("WATCH_PREVIEW_ALLOWANCE");
    int remaining = 79;
    if (allowance != NULL) {
        const char *value = getenv("WATCH_PREVIEW_REMAINING");
        char *end = NULL;
        long parsed = value ? strtol(value, &end, 10) : 79;
        if (strcmp(allowance, "rim") != 0 ||
            (value && (end == value || *end != '\0')) || parsed < -1 || parsed > 100) {
            fputs("allowance must be rim; remaining must be -1 (unavailable) or 0..100\n", stderr);
            return 2;
        }
        remaining = (int)parsed;
    }
    const char *output_path = argc > 1 ? argv[1] : "watchface.ppm";
    watch_face_theme_t theme = WATCH_FACE_DEFAULT_THEME;
    if (argc != 1 && argc != 2 && argc != 5 && argc != 6 && argc != 8) {
        fputs(
            "usage: render-watchface [output.ppm "
            "[background foreground accent [battery% [agent-state frame-prefix]]]]\n",
            stderr
        );
        return 2;
    }
    if (argc >= 5 &&
        (parse_color(argv[2], theme.background) != 0 ||
         parse_color(argv[3], theme.foreground) != 0 ||
         parse_color(argv[4], theme.accent) != 0)) {
        fputs("colors must use #RRGGBB\n", stderr);
        return 2;
    }
    lv_init();

    lv_display_t *display = lv_display_create(WATCH_FACE_WIDTH, WATCH_FACE_HEIGHT);
    if (display == NULL) {
        fputs("Unable to create LVGL display\n", stderr);
        return 1;
    }
    lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);

    const size_t buffer_size = WATCH_FACE_WIDTH * WATCH_FACE_HEIGHT * 2 + LV_DRAW_BUF_ALIGN;
    uint8_t *allocation = malloc(buffer_size);
    if (allocation == NULL) {
        return 1;
    }

    lv_draw_buf_t draw_buffer;
    if (lv_draw_buf_init(&draw_buffer,
                         WATCH_FACE_WIDTH,
                         WATCH_FACE_HEIGHT,
                         LV_COLOR_FORMAT_RGB565,
                         LV_STRIDE_AUTO,
                         lv_draw_buf_align(allocation, LV_COLOR_FORMAT_RGB565),
                         buffer_size) != LV_RESULT_OK) {
        fputs("Unable to initialize LVGL draw buffer\n", stderr);
        free(allocation);
        return 1;
    }
    lv_display_set_draw_buffers(display, &draw_buffer, NULL);
    lv_display_set_render_mode(display, LV_DISPLAY_RENDER_MODE_DIRECT);
    lv_display_set_flush_cb(display, flush_display);

    test_resource_colors();
    watch_face_layout_t layout;
    watch_face_layout_create(lv_screen_active(), &layout, &theme);
    watch_face_layout_set_time(&layout, "Tue 8 Sep", "05:59", "PM");
    watch_face_layout_set_battery(
        &layout, "󰂀", true, argc >= 6 ? atoi(argv[5]) : 70,
        argc >= 6 ? argv[5] : "70%", argc >= 6
    ); // U+F0080, battery-70
    watch_face_layout_set_weather(
        &layout, "", "68°", "PARTLY\nCLOUDY",
        "H 72°  L 61°", " SAN FRANCISCO"
    );
    watch_face_layout_set_agent(&layout, true);
    if (allowance != NULL) {
        watch_face_layout_set_connected(&layout, true);
        watch_face_layout_set_allowance(&layout, remaining, 1, 4 * 86400 + 20 * 3600);
    }
    const char *profile_path = getenv("WATCH_PREVIEW_PROFILE");
    if (profile_path != NULL) {
        omarchy_profile_v5_t packet = {0};
        omarchy_profile_v4_t profile;
        FILE *input = fopen(profile_path, "rb");
        if (input == NULL) { perror(profile_path); return 2; }
        const size_t size = fread(&packet, 1, sizeof(packet), input);
        const bool extra = fgetc(input) != EOF;
        fclose(input);
        profile = packet.base;
        if (extra || !((size == sizeof(packet) && omarchy_profile_v5_is_valid(&packet)) ||
                       (size == sizeof(profile) && omarchy_profile_v4_is_valid(&profile)))) {
            fputs("Invalid preview profile\n", stderr);
            return 2;
        }
        const int64_t now = time(NULL);
        watch_face_layout_set_connected(&layout, true);
        watch_face_layout_set_allowance(&layout,
            omarchy_allowance_remaining(profile.allowance_remaining, profile.allowance_updated_at,
                                        profile.allowance_resets_at, now),
            profile.allowance_window, profile.allowance_resets_at - now);
        watch_face_layout_allowance_age(&layout,
            omarchy_allowance_remaining(profile.allowance_remaining, profile.allowance_updated_at,
                                        profile.allowance_resets_at, now),
            profile.allowance_updated_at, profile.allowance_resets_at, now, false);
    }
    const char *freshness = getenv("WATCH_PREVIEW_FRESHNESS");
    if (freshness) {
        const int64_t now = 1800000000;
        int64_t age = strcmp(freshness, "fresh") == 0 ? 60 : 7200;
        int64_t resets = now + 4 * 86400;
        int64_t daily_end = now + 7200;
        bool detail = strcmp(freshness, "detail") == 0;
        if (strcmp(freshness, "expired") == 0) { age = 14400; resets = now; }
        if (strcmp(freshness, "next-day") == 0) { age = 28800; daily_end = now; resets = now; }
        int left = omarchy_allowance_remaining(54, now-age, resets, now);
        watch_face_layout_set_allowance(&layout, left, 1, resets-now);
        watch_face_layout_allowance_age(&layout, left, now-age, resets, now, detail);
        watch_face_layout_weather_snapshot(&layout, "", "68°", "PARTLY\nCLOUDY",
            "H 72°  L 61°", "", now-age, daily_end, now, detail);
        watch_face_layout_set_connected(&layout, true);
        if (strcmp(freshness, "expired") == 0 || strcmp(freshness, "next-day") == 0) {
            if (strcmp(lv_label_get_text(layout.allowance_reset), "AWAITING UPDATE") ||
                strcmp(lv_label_get_text(layout.temperature), "--°") ||
                !lv_obj_has_flag(layout.allowance_fill, LV_OBJ_FLAG_HIDDEN)) return 1;
        }
        if (strcmp(freshness, "expired") == 0 && strcmp(lv_label_get_text(layout.range), "H 72°  L 61°")) return 1;
        if (strcmp(freshness, "next-day") == 0 && strcmp(lv_label_get_text(layout.range), "H --°  L --°")) return 1;
        if (strcmp(freshness, "cached") == 0 &&
            (lv_obj_has_flag(layout.weather_history, LV_OBJ_FLAG_HIDDEN) ||
             lv_obj_has_flag(layout.allowance_history, LV_OBJ_FLAG_HIDDEN))) return 1;
        if (detail && (strcmp(lv_label_get_text(layout.allowance_reset), "UPDATED 2h AGO") ||
                       strcmp(lv_label_get_text(layout.condition), "UPDATED\n2h AGO"))) return 1;
        if (strcmp(freshness, "fresh") == 0 &&
            (!lv_obj_has_flag(layout.weather_history, LV_OBJ_FLAG_HIDDEN) ||
             !lv_obj_has_flag(layout.allowance_history, LV_OBJ_FLAG_HIDDEN))) return 1;
    }
    if (argc == 8) {
        watch_agent_state_t state;
        if (strcmp(argv[6], "working") == 0) state = WATCH_AGENT_WORKING;
        else if (strcmp(argv[6], "attention") == 0) state = WATCH_AGENT_ATTENTION;
        else if (strcmp(argv[6], "finished") == 0) state = WATCH_AGENT_FINISHED;
        else if (strcmp(argv[6], "idle") == 0) state = WATCH_AGENT_IDLE;
        else {
            fputs("agent-state must be idle, working, attention, or finished\n", stderr);
            return 2;
        }
        /* Start from a visible fixture, including when testing the idle state. */
        layout.agent_state = WATCH_AGENT_FINISHED;
        watch_face_layout_set_agent_state(&layout, state, true);
        const char *expected_glyph = state == WATCH_AGENT_FINISHED ? "󱜙" : "󱚣";
        if (strcmp(lv_label_get_text(layout.agent), expected_glyph) != 0) {
            fputs("Unexpected agent expression\n", stderr);
            return 1;
        }
        const unsigned duration = state == WATCH_AGENT_WORKING ? 5200 :
                                  state == WATCH_AGENT_FINISHED ? 4200 : 4000;
        for (unsigned frame = 0; frame < duration / 40; ++frame) {
            lv_anim_refr_now();
            lv_refr_now(display);
            char frame_path[1024];
            snprintf(frame_path, sizeof(frame_path), "%s-%03u.ppm", argv[7], frame);
            if (write_ppm(frame_path, &draw_buffer) != 0) return 1;
            lv_tick_inc(40);
        }
        /* Sleeping must cancel motion; waking restores it, and idle clears it. */
        watch_face_layout_set_agent_state(&layout, state, false);
        if (lv_anim_count_running() != 0 ||
                lv_obj_get_style_transform_rotation(layout.agent, 0) != 0 ||
                lv_obj_get_style_translate_x(layout.agent, 0) != 0 ||
                lv_obj_get_style_text_opa(layout.agent, 0) != LV_OPA_COVER) {
            fputs("Agent animation did not reset for sleep\n", stderr);
            return 1;
        }
        watch_face_layout_set_agent_state(&layout, state, true);
        if (state != WATCH_AGENT_IDLE && lv_anim_count_running() != 1) {
            fputs("Agent animation did not resume on wake\n", stderr);
            return 1;
        }
        watch_face_layout_set_agent_state(&layout, WATCH_AGENT_IDLE, true);
        if (lv_anim_count_running() != 0 ||
                !lv_obj_has_flag(layout.agent, LV_OBJ_FLAG_HIDDEN)) {
            fputs("Idle agent was not cleared\n", stderr);
            return 1;
        }
    }
    lv_refr_now(display);

    const int result = write_ppm(output_path, &draw_buffer);
    free(allocation);
    return result;
}
