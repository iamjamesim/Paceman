#include "watch_face_layout.h"
#include "watch_rim_geometry.h"
#include "watch_profile.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

LV_FONT_DECLARE(jetbrains_mono_22);

static lv_obj_t *label(int y)
{
    lv_obj_t *obj = lv_label_create(lv_screen_active());
    lv_obj_set_style_text_font(obj, &jetbrains_mono_22, 0);
    lv_obj_set_width(obj, 354);
    lv_obj_set_style_text_align(obj, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_pos(obj, 28, y);
    return obj;
}

void watch_face_layout_set_allowance(watch_face_layout_t *layout, int remaining,
                                     unsigned window, int64_t reset_seconds)
{
    if (layout->allowance_track == NULL) {
        layout->allowance_track = lv_line_create(lv_screen_active());
        layout->allowance_fill = lv_line_create(lv_screen_active());
        layout->allowance_title = label(417);
        layout->allowance_reset = label(447);
        layout->allowance_history = label(417);
        lv_label_set_text(layout->allowance_history, "\uf1da");
        // Leave room for the full glyph, including its negative left bearing.
        lv_obj_set_width(layout->allowance_history, 26);
        lv_obj_set_style_text_align(layout->allowance_history, LV_TEXT_ALIGN_LEFT, 0);
        lv_obj_set_style_pad_left(layout->allowance_history, 2, 0);
        lv_obj_set_pos(layout->allowance_history, 322, 417);
        lv_obj_add_flag(layout->allowance_history, LV_OBJ_FLAG_HIDDEN);
        layout->allowance_touch = lv_obj_create(lv_screen_active());
        lv_obj_remove_style_all(layout->allowance_touch);
        lv_obj_set_pos(layout->allowance_touch, 28, 405);
        lv_obj_set_size(layout->allowance_touch, 354, 78);
        lv_obj_add_flag(layout->allowance_touch, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_remove_flag(layout->allowance_touch, LV_OBJ_FLAG_SCROLLABLE);
        watch_rim_points(layout->allowance_points, WATCH_SCREEN_CORNER_RADIUS, WATCH_RIM_INSET);
        lv_line_set_points(layout->allowance_track, layout->allowance_points, WATCH_RIM_POINT_COUNT);
        lv_obj_set_style_line_width(layout->allowance_track, 3, 0);
        lv_obj_set_style_line_width(layout->allowance_fill, 3, 0);
        lv_obj_set_style_line_rounded(layout->allowance_fill, true, 0);
        lv_obj_set_style_line_opa(layout->allowance_track, LV_OPA_40, 0);
    }
    lv_obj_add_flag(layout->location, LV_OBJ_FLAG_HIDDEN);
    lv_color_t accent = lv_obj_get_style_text_color(layout->agent, 0);
    lv_obj_set_style_line_color(layout->allowance_track, accent, 0);
    lv_obj_set_style_line_color(layout->allowance_fill, accent, 0);
    lv_obj_set_style_text_color(layout->allowance_reset, lv_obj_get_style_text_color(layout->date, 0), 0);
    lv_obj_set_style_text_color(layout->allowance_history, lv_obj_get_style_text_color(layout->date, 0), 0);
    lv_obj_add_flag(layout->allowance_history, LV_OBJ_FLAG_HIDDEN);
    char title[40], reset[48];
    if (remaining < 0 || remaining > 100 || reset_seconds <= 0) {
        remaining = -1;
        snprintf(title, sizeof(title), "CODEX  --%% LEFT");
        snprintf(reset, sizeof(reset), "LIMITS UNAVAILABLE");
    } else {
        snprintf(title, sizeof(title), "CODEX  %d%% LEFT", remaining);
        int64_t minutes = reset_seconds / 60;
        const char *name = window == 1 ? "WEEKLY" : "SESSION";
        if (minutes >= 1440)
            snprintf(reset, sizeof(reset), "%s RESET %lldd %lldh", name,
                     (long long)(minutes / 1440), (long long)(minutes / 60 % 24));
        else if (minutes >= 60)
            snprintf(reset, sizeof(reset), "%s RESET %lldh %lldm", name,
                     (long long)(minutes / 60), (long long)(minutes % 60));
        else snprintf(reset, sizeof(reset), "%s RESET %lldm", name, (long long)(minutes > 0 ? minutes : 1));
    }
    lv_obj_set_style_text_color(layout->allowance_title,
        watch_face_resource_low(remaining) ? accent : lv_obj_get_style_text_color(layout->date, 0), 0);
    if (strcmp(lv_label_get_text(layout->allowance_title), title) != 0)
        lv_label_set_text(layout->allowance_title, title);
    if (strcmp(lv_label_get_text(layout->allowance_reset), reset) != 0)
        lv_label_set_text(layout->allowance_reset, reset);
    if (layout->allowance_drawn && layout->allowance_remaining == remaining) return;
    layout->allowance_drawn = true;
    layout->allowance_remaining = remaining;
    lv_obj_add_flag(layout->allowance_fill, LV_OBJ_FLAG_HIDDEN);
    if (remaining <= 0) return;
    double length = 0;
    for (unsigned i = 1; i < 70; ++i)
        length += hypot(layout->allowance_points[i].x - layout->allowance_points[i-1].x,
                        layout->allowance_points[i].y - layout->allowance_points[i-1].y);
    double budget = length * remaining / 100.0;
    unsigned n = 1;
    layout->allowance_fill_points[0] = layout->allowance_points[0];
    for (unsigned i = 1; i < 70; ++i) {
        lv_point_precise_t a = layout->allowance_points[i-1], b = layout->allowance_points[i];
        double dx = b.x - a.x, dy = b.y - a.y, segment = hypot(dx, dy);
        if (budget < segment) {
            layout->allowance_fill_points[n++] = (lv_point_precise_t){a.x + dx * budget / segment, a.y + dy * budget / segment};
            break;
        }
        layout->allowance_fill_points[n++] = b;
        budget -= segment;
    }
    lv_line_set_points(layout->allowance_fill, layout->allowance_fill_points, n);
    lv_obj_remove_flag(layout->allowance_fill, LV_OBJ_FLAG_HIDDEN);
}

void watch_face_layout_allowance_age(watch_face_layout_t *layout, int remaining,
                                     int64_t updated, int64_t resets, int64_t now, bool show_age)
{
    if (remaining >= 0 && omarchy_data_stale(updated, now))
        lv_obj_remove_flag(layout->allowance_history, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(layout->allowance_history, LV_OBJ_FLAG_HIDDEN);
    if (updated > 0 && resets <= now)
        lv_label_set_text(layout->allowance_reset, "AWAITING UPDATE");
    if (show_age) {
        char text[40];
        watch_face_format_age(text, sizeof(text), updated, now);
        lv_label_set_text(layout->allowance_reset, text);
    }
}
