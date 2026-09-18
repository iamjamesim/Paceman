#include "watch_face_layout.h"
#include "watch_profile.h"
#include <stdio.h>

#include <string.h>

LV_FONT_DECLARE(jetbrains_mono_14_battery);
LV_FONT_DECLARE(jetbrains_mono_22);
LV_FONT_DECLARE(jetbrains_mono_26_connection);
LV_FONT_DECLARE(jetbrains_mono_27);
LV_FONT_DECLARE(jetbrains_mono_30_battery);
LV_FONT_DECLARE(jetbrains_mono_32_agent);
LV_FONT_DECLARE(jetbrains_mono_42);
LV_FONT_DECLARE(jetbrains_mono_48_icons);
LV_FONT_DECLARE(jetbrains_mono_114);

enum {
    SAFE_INLINE = 28,
    TIME_RULE_Y = 225,
    WEATHER_RULE_Y = 389,
};

const watch_face_theme_t WATCH_FACE_DEFAULT_THEME = {
    .background = {0x10, 0x13, 0x15},
    .foreground = {0xCA, 0xCC, 0xCC},
    .accent = {0x79, 0x81, 0x86},
};

static lv_color_t foreground_color;
static lv_color_t accent_color;

static lv_obj_t *make_label(lv_obj_t *parent, const char *text, const lv_font_t *font)
{
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, foreground_color, 0);
    lv_obj_set_style_text_opa(label, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(label, 0, 0);
    return label;
}

static lv_obj_t *make_rule(lv_obj_t *parent, int x, int y, int width, lv_opa_t opacity)
{
    lv_obj_t *rule = lv_obj_create(parent);
    lv_obj_remove_style_all(rule);
    lv_obj_set_pos(rule, x, y);
    lv_obj_set_size(rule, width, 1);
    lv_obj_set_style_bg_color(rule, foreground_color, 0);
    lv_obj_set_style_bg_opa(rule, opacity, 0);
    return rule;
}

void watch_face_layout_create(lv_obj_t *screen,
                              watch_face_layout_t *layout,
                              const watch_face_theme_t *theme)
{
    memset(layout, 0, sizeof(*layout));
    if (theme == NULL) {
        theme = &WATCH_FACE_DEFAULT_THEME;
    }
    const lv_color_t background_color = lv_color_make(
        theme->background[0], theme->background[1], theme->background[2]
    );
    foreground_color = lv_color_make(
        theme->foreground[0], theme->foreground[1], theme->foreground[2]
    );
    accent_color = lv_color_make(
        theme->accent[0], theme->accent[1], theme->accent[2]
    );

    lv_obj_clean(screen);
    lv_obj_remove_style_all(screen);
    lv_obj_set_size(screen, WATCH_FACE_WIDTH, WATCH_FACE_HEIGHT);
    lv_obj_set_style_bg_color(screen, background_color, 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    lv_obj_clear_flag(screen, LV_OBJ_FLAG_SCROLLABLE);

    layout->date = make_label(screen, "", &jetbrains_mono_27);
    lv_obj_set_width(layout->date, 195);
    lv_label_set_long_mode(layout->date, LV_LABEL_LONG_CLIP);
    lv_obj_set_style_text_letter_space(layout->date, 1, 0);
    lv_obj_set_pos(layout->date, SAFE_INLINE, 60);

    // Live power telemetry supplies the battery glyph.
    layout->battery = make_label(screen, "", &jetbrains_mono_30_battery);
    lv_obj_set_style_text_color(layout->battery, accent_color, 0);
    lv_obj_set_size(layout->battery, 44, 30);
    lv_obj_set_style_text_align(layout->battery, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_transform_pivot_x(layout->battery, 22, 0);
    lv_obj_set_style_transform_pivot_y(layout->battery, 15, 0);
    lv_obj_set_style_transform_rotation(layout->battery, 900, 0);
    lv_obj_set_pos(layout->battery, 338, 57);

    // U+F0E7 is Nerd Fonts' Font Awesome bolt.
    layout->battery_charge = make_label(screen, "", &jetbrains_mono_14_battery);
    lv_obj_set_style_text_color(layout->battery_charge, accent_color, 0);
    lv_obj_set_width(layout->battery_charge, 14);
    lv_obj_set_style_text_align(layout->battery_charge, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_pos(layout->battery_charge, 335, 65);
    lv_obj_add_flag(layout->battery_charge, LV_OBJ_FLAG_HIDDEN);

    layout->battery_percentage = make_label(screen, "", &jetbrains_mono_22);
    lv_obj_set_style_text_color(layout->battery_percentage, accent_color, 0);
    lv_obj_set_width(layout->battery_percentage, 60);
    lv_obj_set_style_text_align(layout->battery_percentage, LV_TEXT_ALIGN_RIGHT, 0);
    lv_obj_set_pos(layout->battery_percentage, 322, 64);
    lv_obj_add_flag(layout->battery_percentage, LV_OBJ_FLAG_HIDDEN);

    // U+F0338 is Nerd Fonts' Material Design Icons link-off glyph.
    layout->connection = make_label(screen, "󰌸", &jetbrains_mono_26_connection);
    lv_obj_set_style_text_color(layout->connection, accent_color, 0);
    lv_obj_set_size(layout->connection, 28, 28);
    lv_obj_set_style_text_align(layout->connection, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_pos(layout->connection, 247, 62);

    // Omarchy's Material Design robot-excited glyph (U+F16A3).
    layout->agent = make_label(screen, "󱚣", &jetbrains_mono_32_agent);
    lv_obj_set_style_text_color(layout->agent, accent_color, 0);
    lv_obj_set_size(layout->agent, 38, 38);
    lv_obj_set_style_text_align(layout->agent, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_pos(layout->agent, 285, 53);
    lv_obj_add_flag(layout->agent, LV_OBJ_FLAG_HIDDEN);

    layout->agent_touch = lv_obj_create(screen);
    lv_obj_remove_style_all(layout->agent_touch);
    lv_obj_set_pos(layout->agent_touch, 270, 42);
    lv_obj_set_size(layout->agent_touch, 62, 58);
    lv_obj_add_flag(layout->agent_touch, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(layout->agent_touch, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(layout->agent_touch, LV_OBJ_FLAG_HIDDEN);

    // Keep the visible battery compact while giving it a forgiving touch target.
    layout->battery_touch = lv_obj_create(screen);
    lv_obj_remove_style_all(layout->battery_touch);
    lv_obj_set_pos(layout->battery_touch, 320, 45);
    lv_obj_set_size(layout->battery_touch, 75, 55);
    lv_obj_add_flag(layout->battery_touch, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(layout->battery_touch, LV_OBJ_FLAG_SCROLLABLE);

    layout->clock = make_label(screen, "--:--", &jetbrains_mono_114);
    lv_obj_set_style_text_color(layout->clock, accent_color, 0);
    lv_obj_set_style_text_letter_space(layout->clock, -11, 0);
    lv_label_set_long_mode(layout->clock, LV_LABEL_LONG_CLIP);
    lv_obj_set_size(layout->clock, 310, 114);
    lv_obj_set_pos(layout->clock, SAFE_INLINE - 8, 110);

    layout->meridiem = make_label(screen, "", &jetbrains_mono_27);
    lv_obj_set_pos(layout->meridiem, 330, 120);
    lv_obj_add_flag(layout->meridiem, LV_OBJ_FLAG_HIDDEN);

    // Three optically balanced compartments: time, weather, and location.
    make_rule(screen, SAFE_INLINE, TIME_RULE_Y,
              WATCH_FACE_WIDTH - (SAFE_INLINE * 2), LV_OPA_50);
    make_rule(screen, SAFE_INLINE, WEATHER_RULE_Y,
              WATCH_FACE_WIDTH - (SAFE_INLINE * 2), LV_OPA_50);

    // A synced profile supplies the weather glyph.
    layout->weather_icon = make_label(screen, "", &jetbrains_mono_48_icons);
    lv_label_set_long_mode(layout->weather_icon, LV_LABEL_LONG_CLIP);
    lv_obj_set_size(layout->weather_icon, 64, 64);
    lv_obj_set_pos(layout->weather_icon, 65, 251);

    layout->temperature = make_label(screen, "--°", &jetbrains_mono_42);
    lv_obj_set_width(layout->temperature, 120);
    lv_obj_set_style_text_align(layout->temperature, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_pos(layout->temperature, 38, 312);

    layout->condition = make_label(screen, "WEATHER\nUNAVAILABLE", &jetbrains_mono_27);
    lv_obj_set_style_text_letter_space(layout->condition, 1, 0);
    lv_obj_set_style_text_line_space(layout->condition, 2, 0);
    lv_obj_set_pos(layout->condition, 202, 255);

    layout->range = make_label(screen, "H --°  L --°", &jetbrains_mono_22);
    lv_obj_set_pos(layout->range, 194, 328);

    layout->weather_history = make_label(screen, "\uf1da", &jetbrains_mono_22);
    // The history glyph is wider than its advance and has a negative bearing.
    lv_obj_set_width(layout->weather_history, 26);
    lv_obj_set_style_pad_left(layout->weather_history, 2, 0);
    lv_obj_set_pos(layout->weather_history, 356, 255);
    lv_obj_add_flag(layout->weather_history, LV_OBJ_FLAG_HIDDEN);
    layout->weather_touch = lv_obj_create(screen);
    lv_obj_remove_style_all(layout->weather_touch);
    lv_obj_set_pos(layout->weather_touch, 28, 245);
    lv_obj_set_size(layout->weather_touch, 354, 140);
    lv_obj_add_flag(layout->weather_touch, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_remove_flag(layout->weather_touch, LV_OBJ_FLAG_SCROLLABLE);

    // U+F041 is Nerd Fonts' Font Awesome location marker.
    layout->location = make_label(screen, " LOCATION NOT SET", &jetbrains_mono_27);
    lv_obj_set_width(layout->location, 330);
    lv_obj_set_style_text_align(layout->location, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_letter_space(layout->location, 1, 0);
    lv_label_set_long_mode(layout->location, LV_LABEL_LONG_DOT);
    lv_obj_set_pos(layout->location, 40, 432);
}

void watch_face_layout_set_weather(watch_face_layout_t *layout,
                                   const char *icon,
                                   const char *temperature,
                                   const char *condition,
                                   const char *range,
                                   const char *location)
{
    lv_label_set_text(layout->weather_icon, icon);
    lv_label_set_text(layout->temperature, temperature);
    lv_label_set_text(layout->condition, condition);
    lv_label_set_text(layout->range, range);
    lv_label_set_text(layout->location, location);
}

void watch_face_layout_set_time(watch_face_layout_t *layout,
                                const char *date,
                                const char *clock,
                                const char *meridiem)
{
    lv_label_set_text(layout->date, date);
    lv_label_set_text(layout->clock, clock);
    lv_label_set_text(layout->meridiem, meridiem);
    if (meridiem[0] == '\0') {
        lv_obj_add_flag(layout->meridiem, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_remove_flag(layout->meridiem, LV_OBJ_FLAG_HIDDEN);
    }
}

void watch_face_layout_set_battery(watch_face_layout_t *layout,
                                   const char *glyph,
                                   bool charging,
                                   int percent,
                                   const char *percentage,
                                   bool show_percentage)
{
    const lv_color_t battery_color = charging || watch_face_resource_low(percent)
                                        ? accent_color : foreground_color;
    lv_label_set_text(layout->battery, glyph);
    lv_label_set_text(layout->battery_percentage, percentage);
    lv_obj_set_style_text_color(layout->battery, battery_color, 0);
    lv_obj_set_style_text_color(layout->battery_percentage, battery_color, 0);
    if (show_percentage) {
        lv_obj_add_flag(layout->battery, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(layout->battery_charge, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(layout->battery_percentage, LV_OBJ_FLAG_HIDDEN);
        return;
    }

    lv_obj_add_flag(layout->battery_percentage, LV_OBJ_FLAG_HIDDEN);
    if (glyph[0] == '\0') {
        lv_obj_add_flag(layout->battery, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_remove_flag(layout->battery, LV_OBJ_FLAG_HIDDEN);
    }
    if (charging) {
        lv_obj_remove_flag(layout->battery_charge, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(layout->battery_charge, LV_OBJ_FLAG_HIDDEN);
    }
}

void watch_face_layout_set_connected(watch_face_layout_t *layout, bool connected)
{
    if (connected) {
        lv_obj_add_flag(layout->connection, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_remove_flag(layout->connection, LV_OBJ_FLAG_HIDDEN);
    }
}

void watch_face_layout_set_agent(watch_face_layout_t *layout, bool visible)
{
    if (visible) {
        lv_obj_remove_flag(layout->agent, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(layout->agent_touch, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(layout->agent, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(layout->agent_touch, LV_OBJ_FLAG_HIDDEN);
    }
}

static void agent_bounce(void *object, int32_t y)
{
    lv_obj_set_y(object, y);
}

static void agent_pulse(void *object, int32_t opacity)
{
    lv_obj_set_style_text_opa(object, opacity, 0);
}

static void agent_sway(void *object, int32_t phase)
{
    const int32_t wave = lv_trigo_sin(phase);
    const int32_t rounding = wave < 0 ? -16384 : 16384;
    lv_obj_set_style_translate_x(object, (wave * 2 + rounding) / 32768, 0);
    /* LVGL rotation uses tenths of a degree: a relaxed +/-4 degree tilt. */
    lv_obj_set_style_transform_rotation(object, wave * 40 / 32768, 0);
}

void watch_face_layout_set_agent_state(watch_face_layout_t *layout,
                                       watch_agent_state_t state, bool animate)
{
    if (layout->agent_state == state && layout->agent_animated == animate) {
        return;
    }
    layout->agent_state = state;
    layout->agent_animated = animate;
    lv_obj_t *agent = layout->agent;
    lv_label_set_text(agent, state == WATCH_AGENT_FINISHED ? "󱜙" : "󱚣");
    lv_anim_delete(agent, NULL);
    lv_obj_set_y(agent, 53);
    lv_obj_set_style_translate_x(agent, 0, 0);
    lv_obj_set_style_transform_rotation(agent, 0, 0);
    lv_obj_set_style_text_opa(agent, LV_OPA_COVER, 0);
    watch_face_layout_set_agent(layout, state != WATCH_AGENT_IDLE);
    if (!animate || state == WATCH_AGENT_IDLE) {
        return;
    }

    lv_anim_t animation;
    lv_anim_init(&animation);
    lv_anim_set_var(&animation, agent);
    lv_anim_set_repeat_count(&animation, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&animation, lv_anim_path_ease_in_out);
    switch (state) {
    case WATCH_AGENT_WORKING:
        lv_anim_set_exec_cb(&animation, agent_pulse);
        lv_anim_set_values(&animation, LV_OPA_COVER, 100);
        lv_anim_set_duration(&animation, 1300);
        lv_anim_set_playback_duration(&animation, 1300);
        break;
    case WATCH_AGENT_ATTENTION:
        /* Preserve the original attention bounce exactly. */
        lv_anim_set_exec_cb(&animation, agent_bounce);
        lv_anim_set_values(&animation, 53, 47);
        lv_anim_set_duration(&animation, 320);
        lv_anim_set_playback_duration(&animation, 320);
        lv_anim_set_repeat_delay(&animation, 360);
        break;
    case WATCH_AGENT_FINISHED:
        lv_obj_set_style_transform_pivot_x(agent, 19, 0);
        lv_obj_set_style_transform_pivot_y(agent, 19, 0);
        lv_anim_set_exec_cb(&animation, agent_sway);
        lv_anim_set_values(&animation, 0, 360);
        lv_anim_set_duration(&animation, 4200);
        lv_anim_set_path_cb(&animation, lv_anim_path_linear);
        break;
    default:
        return;
    }
    lv_anim_start(&animation);
}

void watch_face_format_age(char *text, unsigned size, int64_t updated, int64_t now)
{
    if (updated <= 0 || updated > now) {
        snprintf(text, size, "NOT UPDATED");
        return;
    }
    int64_t age = now - updated;
    if (age < 60) snprintf(text, size, "UPDATED JUST NOW");
    else if (age < 3600) snprintf(text, size, "UPDATED %lldm AGO", (long long)(age / 60));
    else if (age < 86400) snprintf(text, size, "UPDATED %lldh AGO", (long long)(age / 3600));
    else snprintf(text, size, "UPDATED %lldd AGO", (long long)(age / 86400));
}

void watch_face_layout_weather_age(watch_face_layout_t *layout, int64_t updated, int64_t now,
                                   bool current_visible, bool show_age)
{
    if (current_visible && omarchy_data_stale(updated, now))
        lv_obj_remove_flag(layout->weather_history, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(layout->weather_history, LV_OBJ_FLAG_HIDDEN);
    if (show_age) {
        char text[40];
        watch_face_format_age(text, sizeof(text), updated, now);
        char *space = strchr(text, ' ');
        if (space) *space = '\n';
        lv_label_set_text(layout->condition, text);
    }
}

void watch_face_layout_weather_snapshot(watch_face_layout_t *layout,
    const char *icon, const char *temperature, const char *condition, const char *range,
    const char *location, int64_t updated, int64_t daily_expires, int64_t now, bool show_age)
{
    bool current = omarchy_weather_current(updated, now);
    bool daily = updated > 0 && updated <= now && daily_expires > now;
    watch_face_layout_set_weather(layout, current ? icon : "", current ? temperature : "--°",
        current ? condition : "", daily ? range : "H --°  L --°", location);
    watch_face_layout_weather_age(layout, updated, now, current, show_age);
}
