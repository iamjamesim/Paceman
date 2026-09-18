#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "lvgl.h"

enum {
    WATCH_FACE_WIDTH = 410,
    WATCH_FACE_HEIGHT = 502,
};

typedef enum {
    WATCH_AGENT_IDLE,
    WATCH_AGENT_WORKING,
    WATCH_AGENT_ATTENTION,
    WATCH_AGENT_FINISHED,
} watch_agent_state_t;

typedef struct {
    uint8_t background[3];
    uint8_t foreground[3];
    uint8_t accent[3];
} watch_face_theme_t;

typedef struct {
    lv_obj_t *date;
    lv_obj_t *clock;
    lv_obj_t *meridiem;
    lv_obj_t *battery;
    lv_obj_t *battery_charge;
    lv_obj_t *battery_percentage;
    lv_obj_t *battery_touch;
    lv_obj_t *connection;
    lv_obj_t *agent;
    lv_obj_t *agent_touch;
    watch_agent_state_t agent_state;
    bool agent_animated;
    lv_obj_t *weather_history;
    lv_obj_t *weather_touch;
    lv_obj_t *allowance_touch;
    lv_obj_t *allowance_history;
    lv_obj_t *weather_icon;
    lv_obj_t *temperature;
    lv_obj_t *condition;
    lv_obj_t *range;
    lv_obj_t *location;
    lv_obj_t *allowance_track;
    lv_obj_t *allowance_fill;
    lv_obj_t *allowance_title;
    lv_obj_t *allowance_reset;
    lv_point_precise_t allowance_points[70];
    lv_point_precise_t allowance_fill_points[70];
    int allowance_remaining;
    bool allowance_drawn;
} watch_face_layout_t;

extern const watch_face_theme_t WATCH_FACE_DEFAULT_THEME;
void watch_face_layout_weather_snapshot(watch_face_layout_t *layout,
    const char *icon, const char *temperature, const char *condition, const char *range,
    const char *location, int64_t updated, int64_t daily_expires, int64_t now, bool show_age);
void watch_face_layout_weather_age(watch_face_layout_t *layout, int64_t updated, int64_t now,
                                   bool current_visible, bool show_age);
void watch_face_layout_allowance_age(watch_face_layout_t *layout, int remaining,
                                     int64_t updated, int64_t resets, int64_t now, bool show_age);
void watch_face_format_age(char *text, unsigned size, int64_t updated, int64_t now);
/* Unknown readings must not be presented as a low resource warning. */
static inline bool watch_face_resource_low(int percent)
{
    return percent >= 0 && percent <= 20;
}
void watch_face_layout_set_allowance(watch_face_layout_t *layout, int remaining,
                                     unsigned window, int64_t reset_seconds);

void watch_face_layout_create(lv_obj_t *screen,
                              watch_face_layout_t *layout,
                              const watch_face_theme_t *theme);
void watch_face_layout_set_time(watch_face_layout_t *layout,
                                const char *date,
                                const char *clock,
                                const char *meridiem);
void watch_face_layout_set_battery(watch_face_layout_t *layout,
                                   const char *glyph,
                                   bool charging,
                                   int percent,
                                   const char *percentage,
                                   bool show_percentage);
void watch_face_layout_set_connected(watch_face_layout_t *layout, bool connected);
void watch_face_layout_set_agent(watch_face_layout_t *layout, bool visible);
void watch_face_layout_set_agent_state(watch_face_layout_t *layout,
                                       watch_agent_state_t state, bool animate);
void watch_face_layout_set_weather(watch_face_layout_t *layout,
                                   const char *icon,
                                   const char *temperature,
                                   const char *condition,
                                   const char *range,
                                   const char *location);
