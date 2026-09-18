#include "watch_ui.h"

#include <stdio.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>

#include "bsp/esp-bsp.h"
#include "bsp/display.h"
#include "bsp/touch.h"
#include "driver/gpio.h"
#include "esp_lvgl_port.h"
#include "esp_sleep.h"
#include "lvgl.h"
#include "watch_ble.h"
#include "watch_face_layout.h"
#include "watch_haptics.h"
#include "watch_power.h"
#include "watch_sound.h"

LV_FONT_DECLARE(jetbrains_mono_27);
LV_FONT_DECLARE(jetbrains_mono_42);
LV_FONT_DECLARE(jetbrains_mono_114);

_Static_assert((int)WATCH_AGENT_IDLE == OMARCHY_ACTIVITY_NONE &&
               (int)WATCH_AGENT_WORKING == OMARCHY_ACTIVITY_WORKING &&
               (int)WATCH_AGENT_ATTENTION == OMARCHY_ACTIVITY_ATTENTION &&
               (int)WATCH_AGENT_FINISHED == OMARCHY_ACTIVITY_FINISHED,
               "Agent presentation and protocol states must agree");

enum {
    DISPLAY_WIDTH = 410,
    DISPLAY_HEIGHT = 502,
    SAFE_INLINE = 28,
    DEFAULT_BRIGHTNESS_PERCENT = 50,
    PAIRING_BRIGHTNESS_PERCENT = 75,
    DISPLAY_TIMEOUT_MS = 15000,
    DISPLAY_PREVIEW_TIMEOUT_MS = 5000,
    DISPLAY_PREVIEW_MIN_BATTERY_PERCENT = 15,
    BATTERY_PERCENTAGE_TIMEOUT_MS = 3000,
    WEATHER_MAX_AGE_SECONDS = 6 * 60 * 60,
    DISPLAY_BUFFER_HEIGHT = 100,
    DISPLAY_IDLE_TASK_SLEEP_MS = 10000,
};

static watch_face_layout_t face_layout;
static lv_timer_t *clock_timer;
static lv_timer_t *battery_timer;
static lv_timer_t *battery_percentage_timer;
static lv_timer_t *display_timer;
static bool face_visible;
static bool display_awake = true;
static bool pairing_visible;
static bool battery_percentage_visible;
static bool battery_percentage_available;
static bool ble_connected;
static uint8_t agent_activity_state;
static uint32_t agent_tap_allowed_after;
static int16_t utc_offset_minutes;
static uint8_t hour_cycle = 24;
static uint8_t active_brightness_percent = DEFAULT_BRIGHTNESS_PERCENT;
static watch_face_theme_t face_theme = {
    .background = {0x10, 0x13, 0x15},
    .foreground = {0xCA, 0xCC, 0xCC},
    .accent = {0x79, 0x81, 0x86},
};
static bool weather_valid;
static bool allowance_supported;
static bool freshness_supported;
static int64_t weather_daily_expires_at;
static uint32_t weather_detail_until;
static uint32_t allowance_detail_until;
static uint8_t allowance_remaining = 255;
static uint8_t allowance_window;
static int64_t allowance_updated_at;
static int64_t allowance_resets_at;
static int64_t weather_updated_at;
static int16_t weather_temperature;
static int16_t weather_high;
static int16_t weather_low;
static uint8_t weather_code;
static bool weather_night;
static char weather_location[24] = "SAN FRANCISCO";
static lv_indev_t *display_input;
static esp_lcd_panel_handle_t display_panel;

static void arm_display_timeout(uint32_t timeout_ms);

static uint8_t effective_brightness_percent(void)
{
    if (pairing_visible && active_brightness_percent < PAIRING_BRIGHTNESS_PERCENT) {
        return PAIRING_BRIGHTNESS_PERCENT;
    }
    return active_brightness_percent;
}

static void round_display_area(lv_area_t *area)
{
    area->x1 &= ~1;
    area->y1 &= ~1;
    area->x2 |= 1;
    area->y2 |= 1;
}

static lv_display_t *start_display(const lvgl_port_cfg_t *port_cfg)
{
    if (lvgl_port_init(port_cfg) != ESP_OK) {
        return NULL;
    }

    const bsp_display_config_t panel_cfg = {
        .max_transfer_sz = DISPLAY_WIDTH * DISPLAY_HEIGHT * BSP_LCD_BITS_PER_PIXEL / 8,
    };
    esp_lcd_panel_io_handle_t io = NULL;
    if (bsp_display_new(&panel_cfg, &display_panel, &io) != ESP_OK ||
        bsp_display_brightness_set(0) != ESP_OK) {
        return NULL;
    }

    const lvgl_port_display_cfg_t display_cfg = {
        .io_handle = io,
        .panel_handle = display_panel,
        .buffer_size = DISPLAY_WIDTH * DISPLAY_BUFFER_HEIGHT,
        .monochrome = false,
        .hres = DISPLAY_WIDTH,
        .vres = DISPLAY_HEIGHT,
        .color_format = LV_COLOR_FORMAT_RGB565,
        .rounder_cb = round_display_area,
        .rotation = {
            .swap_xy = false,
            .mirror_x = false,
            .mirror_y = false,
        },
        .flags = {
            .sw_rotate = true,
            .buff_dma = false,
            .buff_spiram = false,
            .swap_bytes = true,
        },
    };
    lv_display_t *display = lvgl_port_add_disp(&display_cfg);
    if (display == NULL) {
        return NULL;
    }

    esp_lcd_touch_handle_t touch = NULL;
    if (bsp_touch_new(NULL, &touch) != ESP_OK) {
        return NULL;
    }
    const lvgl_port_touch_cfg_t touch_cfg = {
        .disp = display,
        .handle = touch,
    };
    display_input = lvgl_port_add_touch(&touch_cfg);
    return display_input == NULL ? NULL : display;
}

static void render_full_screen_locked(void)
{
    lv_obj_invalidate(lv_screen_active());
    lv_refr_now(lv_display_get_default());
}

static void present_screen_locked(void)
{
    if (!display_awake) {
        return;
    }
    render_full_screen_locked();
    bsp_display_brightness_set(effective_brightness_percent());
    arm_display_timeout(DISPLAY_TIMEOUT_MS);
}

static void update_agent(void)
{
    if (!face_visible) {
        return;
    }
    watch_face_layout_set_agent_state(
        &face_layout, (watch_agent_state_t)agent_activity_state, display_awake
    );
}

static void update_connection(void)
{
    if (!face_visible) {
        return;
    }
    watch_face_layout_set_connected(&face_layout, ble_connected);
}

static lv_color_t foreground_color(void)
{
    return lv_color_make(
        face_theme.foreground[0], face_theme.foreground[1], face_theme.foreground[2]
    );
}

static lv_color_t accent_color(void)
{
    return lv_color_make(
        face_theme.accent[0], face_theme.accent[1], face_theme.accent[2]
    );
}

static lv_obj_t *make_label(lv_obj_t *parent, const char *text, const lv_font_t *font)
{
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, foreground_color(), 0);
    lv_obj_set_style_text_opa(label, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(label, 0, 0);
    return label;
}

static lv_obj_t *reset_screen(void)
{
    lv_obj_t *screen = lv_screen_active();
    lv_obj_clean(screen);
    lv_obj_remove_style_all(screen);
    lv_obj_set_size(screen, DISPLAY_WIDTH, DISPLAY_HEIGHT);
    lv_obj_set_style_bg_color(
        screen,
        lv_color_make(face_theme.background[0], face_theme.background[1], face_theme.background[2]),
        0
    );
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    lv_obj_clear_flag(screen, LV_OBJ_FLAG_SCROLLABLE);

    face_visible = false;
    pairing_visible = false;
    if (clock_timer != NULL) {
        lv_timer_delete(clock_timer);
        clock_timer = NULL;
    }
    if (battery_timer != NULL) {
        lv_timer_delete(battery_timer);
        battery_timer = NULL;
    }
    if (battery_percentage_timer != NULL) {
        lv_timer_delete(battery_percentage_timer);
        battery_percentage_timer = NULL;
    }
    battery_percentage_visible = false;
    battery_percentage_available = false;
    weather_detail_until = allowance_detail_until = 0;
    if (display_awake) {
        arm_display_timeout(DISPLAY_TIMEOUT_MS);
    }
    return screen;
}

static void update_allowance(void)
{
    if (!face_visible || !allowance_supported) return;
    const int64_t now = time(NULL);
    const int remaining = omarchy_allowance_remaining(allowance_remaining, allowance_updated_at,
                                                     allowance_resets_at, now);
    watch_face_layout_set_allowance(&face_layout, remaining,
                                    allowance_window, allowance_resets_at - now);
    watch_face_layout_allowance_age(&face_layout, remaining, allowance_updated_at,
                                    allowance_resets_at, now,
                                    allowance_detail_until && (int32_t)(allowance_detail_until - lv_tick_get()) > 0);
}

static void update_weather(void);

static void update_clock(lv_timer_t *timer)
{
    (void)timer;
    if (!face_visible || !display_awake) {
        return;
    }

    time_t shifted = time(NULL) + (utc_offset_minutes * 60);
    struct tm now;
    gmtime_r(&shifted, &now);

    static const char *weekdays[] = {
        "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
    };
    static const char *months[] = {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    char date[24];
    char clock[8];
    snprintf(date, sizeof(date), "%s %d %s",
             weekdays[now.tm_wday], now.tm_mday, months[now.tm_mon]);

    int display_hour = now.tm_hour;
    const char *suffix = "";
    if (hour_cycle == 12) {
        suffix = now.tm_hour >= 12 ? "PM" : "AM";
        display_hour %= 12;
        if (display_hour == 0) {
            display_hour = 12;
        }
    }

    snprintf(clock, sizeof(clock), "%02d:%02d", display_hour, now.tm_min);
    watch_face_layout_set_time(&face_layout, date, clock, suffix);
    update_weather();
}

static void update_battery(lv_timer_t *timer)
{
    (void)timer;
    if (!face_visible || !display_awake) {
        return;
    }

    // Nerd Fonts' Material Design Icons battery-10 through battery-90,
    // followed by the full battery glyph.
    static const char *battery_icons[] = {
        "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹",
    };
    watch_power_state_t state;
    const char *glyph;
    char percentage[5] = "";
    bool charging = false;
    battery_percentage_available = false;
    if (watch_power_read(&state) != ESP_OK) {
        glyph = "󰂑";
    } else if (!state.battery_present) {
        glyph = state.external_power ? "" : "󰂑";
        charging = state.external_power;
    } else {
        const uint8_t index = state.percent >= 100 ? 9 : state.percent / 10;
        glyph = battery_icons[index];
        charging = state.charging;
        snprintf(
            percentage, sizeof(percentage), "%u%%", (unsigned int)state.percent
        );
        battery_percentage_available = true;
    }
    watch_face_layout_set_battery(
        &face_layout, glyph, charging,
        battery_percentage_available ? state.percent : -1, percentage,
        battery_percentage_visible && battery_percentage_available
    );
}

static void hide_battery_percentage(lv_timer_t *timer)
{
    (void)timer;
    battery_percentage_timer = NULL;
    battery_percentage_visible = false;
    update_battery(NULL);
}

static void on_battery_tap(lv_event_t *event)
{
    (void)event;
    if (!face_visible || !display_awake) {
        return;
    }
    update_battery(NULL);
    if (!battery_percentage_available) {
        return;
    }
    battery_percentage_visible = true;
    update_battery(NULL);
    if (battery_percentage_timer != NULL) {
        lv_timer_delete(battery_percentage_timer);
    }
    battery_percentage_timer = lv_timer_create(
        hide_battery_percentage, BATTERY_PERCENTAGE_TIMEOUT_MS, NULL
    );
    lv_timer_set_repeat_count(battery_percentage_timer, 1);
}

static void on_agent_tap(lv_event_t *event)
{
    (void)event;
    if (!face_visible || !display_awake ||
        (agent_activity_state != OMARCHY_ACTIVITY_ATTENTION &&
         agent_activity_state != OMARCHY_ACTIVITY_FINISHED) ||
        (int32_t)(agent_tap_allowed_after - lv_tick_get()) > 0) {
        return;
    }
    agent_activity_state = OMARCHY_ACTIVITY_NONE;
    update_agent();
    watch_ble_acknowledge_activity();
}

static const char *weather_icon_for_code(uint8_t code, bool night)
{
    if (code == 0) return night ? "" : "";
    if (code <= 2) return night ? "" : "";
    if (code == 3) return "";
    if (code == 45 || code == 48) return night ? "" : "";
    if (code >= 51 && code <= 61) return night ? "" : "";
    if ((code >= 63 && code <= 67) || (code >= 80 && code <= 82)) return "";
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) return "";
    if (code >= 95) return "";
    return "";
}

static const char *weather_condition_for_code(uint8_t code)
{
    if (code == 0) return "CLEAR";
    if (code <= 2) return "PARTLY\nCLOUDY";
    if (code == 3) return "OVERCAST";
    if (code == 45 || code == 48) return "FOG";
    if (code >= 51 && code <= 57) return "DRIZZLE";
    if ((code >= 61 && code <= 67)) return "RAIN";
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) return "SNOW";
    if (code >= 80 && code <= 82) return "SHOWERS";
    if (code >= 95) return "THUNDER\nSTORM";
    return "WEATHER\nUNKNOWN";
}

static void update_weather(void)
{
    if (!face_visible) {
        return;
    }

    char temperature[12];
    char range[24];
    char location[32];
    const int64_t weather_age = (int64_t)time(NULL) - weather_updated_at;
    const int64_t now = time(NULL);
    if (freshness_supported) {
        snprintf(temperature, sizeof(temperature), "%d°", weather_temperature);
        snprintf(range, sizeof(range), "H %d°  L %d°", weather_high, weather_low);
        snprintf(location, sizeof(location), " %s", weather_location);
        watch_face_layout_weather_snapshot(&face_layout,
            weather_icon_for_code(weather_code, weather_night), temperature,
            weather_condition_for_code(weather_code), range, location,
            weather_valid ? weather_updated_at : 0, weather_daily_expires_at, now,
            weather_detail_until && (int32_t)(weather_detail_until - lv_tick_get()) > 0);
        update_allowance();
        return;
    }
    const bool weather_is_fresh = weather_valid && weather_age >= 0 &&
                                  weather_age <= WEATHER_MAX_AGE_SECONDS;
    if (weather_is_fresh) {
        snprintf(temperature, sizeof(temperature), "%d°", weather_temperature);
        snprintf(range, sizeof(range), "H %d°  L %d°", weather_high, weather_low);
        snprintf(location, sizeof(location), " %s", weather_location);
        watch_face_layout_set_weather(
            &face_layout,
            weather_icon_for_code(weather_code, weather_night),
            temperature,
            weather_condition_for_code(weather_code),
            range,
            location
        );
    } else {
        watch_face_layout_set_weather(&face_layout, "", "--°", "", "H --°  L --°", "");
    }
    watch_face_layout_weather_age(&face_layout, weather_valid ? weather_updated_at : 0,
        now, weather_is_fresh, weather_detail_until && (int32_t)(weather_detail_until - lv_tick_get()) > 0);
    update_allowance();
}

static void display_sleep(lv_timer_t *timer)
{
    (void)timer;
    display_timer = NULL;
    if (!display_awake || pairing_visible) {
        return;
    }
    display_awake = false;
    update_agent();
    if (clock_timer != NULL) lv_timer_pause(clock_timer);
    if (battery_timer != NULL) lv_timer_pause(battery_timer);
    lvgl_port_stop();
    bsp_display_brightness_set(0);
    esp_lcd_panel_disp_on_off(display_panel, false);
}

static void arm_display_timeout(uint32_t timeout_ms)
{
    if (!display_awake) {
        return;
    }
    if (display_timer != NULL) {
        lv_timer_delete(display_timer);
        display_timer = NULL;
    }
    if (pairing_visible) {
        return;
    }
    display_timer = lv_timer_create(display_sleep, timeout_ms, NULL);
    lv_timer_set_repeat_count(display_timer, 1);
}

static void wake_display_locked(uint32_t timeout_ms)
{
    if (!display_awake) {
        esp_lcd_panel_disp_on_off(display_panel, true);
        lvgl_port_resume();
        display_awake = true;
        if (clock_timer != NULL) {
            lv_timer_resume(clock_timer);
            update_clock(NULL);
        }
        if (battery_timer != NULL) {
            lv_timer_resume(battery_timer);
            update_battery(NULL);
        }
        update_weather();
        update_connection();
        update_agent();
        render_full_screen_locked();
    }
    bsp_display_brightness_set(effective_brightness_percent());
    arm_display_timeout(timeout_ms);
}

static void on_touch(lv_event_t *event)
{
    (void)event;
    if (!display_awake) {
        // A wake gesture must not also acknowledge a hidden alert beneath it.
        agent_tap_allowed_after = lv_tick_get() + 600;
    }
    wake_display_locked(DISPLAY_TIMEOUT_MS);
}

static bool display_preview_allowed(void)
{
    watch_power_state_t state;
    if (watch_power_read(&state) != ESP_OK || state.external_power || !state.battery_present) {
        return true;
    }
    return state.percent > DISPLAY_PREVIEW_MIN_BATTERY_PERCENT;
}

static bool begin_display_preview(bool requested)
{
    if (!requested || display_awake || !display_preview_allowed()) {
        return false;
    }
    esp_lcd_panel_disp_on_off(display_panel, true);
    lvgl_port_resume();
    display_awake = true;
    return true;
}

static void finish_profile_update(bool preview_started)
{
    if (!display_awake) {
        return;
    }
    bsp_display_brightness_set(active_brightness_percent);
    if (preview_started) {
        bsp_display_lock(0);
        update_agent();
        arm_display_timeout(DISPLAY_PREVIEW_TIMEOUT_MS);
        bsp_display_unlock();
    }
}

esp_err_t watch_ui_start(void)
{
    lvgl_port_cfg_t port_cfg = ESP_LVGL_PORT_INIT_CONFIG();
    port_cfg.timer_period_ms = 20;
    port_cfg.task_max_sleep_ms = DISPLAY_IDLE_TASK_SLEEP_MS;
    if (start_display(&port_cfg) == NULL) {
        return ESP_FAIL;
    }

    lv_indev_add_event_cb(display_input, on_touch, LV_EVENT_PRESSED, NULL);
    gpio_wakeup_enable(BSP_LCD_TOUCH_INT, GPIO_INTR_LOW_LEVEL);
    esp_sleep_enable_gpio_wakeup();
    return ESP_OK;
}

void watch_ui_show_pairing(uint32_t passkey)
{
    char code[16];
    snprintf(code, sizeof(code), "%03lu %03lu",
             (unsigned long)(passkey / 1000), (unsigned long)(passkey % 1000));

    bsp_display_lock(0);
    lv_obj_t *screen = reset_screen();
    pairing_visible = true;

    lv_obj_t *eyebrow = make_label(screen, "PAIR WITH OMARCHY", &jetbrains_mono_27);
    lv_obj_set_style_text_letter_space(eyebrow, 1, 0);
    lv_obj_set_pos(eyebrow, SAFE_INLINE, 146);

    lv_obj_t *pin = make_label(screen, code, &jetbrains_mono_42);
    lv_obj_set_style_text_color(pin, foreground_color(), 0);
    lv_obj_set_style_text_letter_space(pin, 2, 0);
    lv_obj_set_pos(pin, SAFE_INLINE, 205);

    lv_obj_t *hint = make_label(screen, "ENTER CODE ON DESKTOP", &jetbrains_mono_27);
    lv_obj_set_style_text_letter_space(hint, 1, 0);
    lv_obj_set_pos(hint, SAFE_INLINE, 283);
    present_screen_locked();
    bsp_display_unlock();
}

void watch_ui_show_time_unavailable(void)
{
    bsp_display_lock(0);
    lv_obj_t *screen = reset_screen();

    lv_obj_t *eyebrow = make_label(screen, "TIME NOT SET", &jetbrains_mono_27);
    lv_obj_set_style_text_letter_space(eyebrow, 1, 0);
    lv_obj_set_pos(eyebrow, SAFE_INLINE, 126);

    lv_obj_t *clock = make_label(screen, "--:--", &jetbrains_mono_114);
    lv_obj_set_style_text_color(clock, accent_color(), 0);
    lv_obj_set_style_text_letter_space(clock, -11, 0);
    lv_label_set_long_mode(clock, LV_LABEL_LONG_CLIP);
    lv_obj_set_size(clock, 310, 114);
    lv_obj_set_pos(clock, SAFE_INLINE - 8, 174);

    lv_obj_t *hint = make_label(screen, "CONNECT TO OMARCHY", &jetbrains_mono_27);
    lv_obj_set_style_text_letter_space(hint, 1, 0);
    lv_obj_set_pos(hint, SAFE_INLINE, 318);
    present_screen_locked();
    bsp_display_unlock();
}

static void on_weather_tap(lv_event_t *event)
{
    (void)event;
    if (!display_awake || (int32_t)(agent_tap_allowed_after - lv_tick_get()) > 0) return;
    weather_detail_until = lv_tick_get() + 3000;
    update_weather();
}

static void on_allowance_tap(lv_event_t *event)
{
    (void)event;
    if (!display_awake || (int32_t)(agent_tap_allowed_after - lv_tick_get()) > 0) return;
    allowance_detail_until = lv_tick_get() + 3000;
    update_allowance();
}

void watch_ui_show_face(void)
{
    bsp_display_lock(0);
    lv_obj_t *screen = reset_screen();
    watch_face_layout_create(screen, &face_layout, &face_theme);
    face_visible = true;
    lv_obj_add_event_cb(
        face_layout.battery_touch, on_battery_tap, LV_EVENT_CLICKED, NULL
    );
    lv_obj_add_event_cb(
        face_layout.agent_touch, on_agent_tap, LV_EVENT_CLICKED, NULL
    );

    update_clock(NULL);
    update_battery(NULL);
    update_weather();
    update_connection();
    update_agent();
    lv_obj_add_event_cb(face_layout.weather_touch, on_weather_tap, LV_EVENT_CLICKED, NULL);
    if (face_layout.allowance_touch)
        lv_obj_add_event_cb(face_layout.allowance_touch, on_allowance_tap, LV_EVENT_CLICKED, NULL);
    clock_timer = lv_timer_create(update_clock, 1000, NULL);
    battery_timer = lv_timer_create(update_battery, 15000, NULL);
    present_screen_locked();
    bsp_display_unlock();
}

void watch_ui_show_error(const char *message)
{
    bsp_display_lock(0);
    lv_obj_t *screen = reset_screen();
    lv_obj_t *label = make_label(screen, message, &jetbrains_mono_27);
    lv_obj_set_width(label, DISPLAY_WIDTH - (SAFE_INLINE * 2));
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_set_pos(label, SAFE_INLINE, 220);
    present_screen_locked();
    bsp_display_unlock();
}

static void apply_time(int64_t unix_time, int16_t offset_minutes, uint8_t cycle)
{
    struct timeval current = {
        .tv_sec = (time_t)unix_time,
        .tv_usec = 0,
    };
    settimeofday(&current, NULL);
    utc_offset_minutes = offset_minutes;
    hour_cycle = cycle == 12 ? 12 : 24;
    watch_ui_show_face();
}

void watch_ui_apply_time(int64_t unix_time, int16_t offset_minutes, uint8_t cycle)
{
    /* A v1 desktop has no allowance fields, including after a live downgrade. */
    allowance_supported = false;
    freshness_supported = false;
    apply_time(unix_time, offset_minutes, cycle);
}

static void apply_weather(const omarchy_profile_v2_t *profile)
{
    weather_valid = (profile->flags & OMARCHY_PROFILE_WEATHER_VALID) != 0;
    weather_updated_at = profile->weather_updated_at;
    weather_temperature = profile->temperature;
    weather_high = profile->high_temperature;
    weather_low = profile->low_temperature;
    weather_code = profile->weather_code;
    weather_night = (profile->flags & OMARCHY_PROFILE_WEATHER_NIGHT) != 0;
    memcpy(weather_location, profile->location, sizeof(weather_location));
    weather_location[sizeof(weather_location) - 1] = '\0';
}

void watch_ui_apply_profile_v2(const omarchy_profile_v2_t *profile)
{
    if (profile == NULL) {
        return;
    }
    allowance_supported = false;
    freshness_supported = false;
    memcpy(face_theme.background, profile->background_rgb, sizeof(face_theme.background));
    memcpy(face_theme.foreground, profile->foreground_rgb, sizeof(face_theme.foreground));
    memcpy(face_theme.accent, profile->foreground_rgb, sizeof(face_theme.accent));
    active_brightness_percent = DEFAULT_BRIGHTNESS_PERCENT;
    apply_weather(profile);
    apply_time(profile->unix_time, profile->utc_offset_minutes, profile->hour_cycle);
    finish_profile_update(false);
}

void watch_ui_apply_profile_v3(const omarchy_profile_v3_t *profile)
{
    if (profile == NULL) {
        return;
    }
    allowance_supported = profile->version >= 4;
    freshness_supported = profile->version >= 5;
    const bool preview_started = begin_display_preview(
        (profile->flags & OMARCHY_PROFILE_DISPLAY_PREVIEW) != 0
    );
    memcpy(face_theme.background, profile->background_rgb, sizeof(face_theme.background));
    memcpy(face_theme.foreground, profile->foreground_rgb, sizeof(face_theme.foreground));
    memcpy(face_theme.accent, profile->accent_rgb, sizeof(face_theme.accent));
    active_brightness_percent = profile->brightness_percent;
    apply_weather((const omarchy_profile_v2_t *)profile);
    apply_time(profile->unix_time, profile->utc_offset_minutes, profile->hour_cycle);
    finish_profile_update(preview_started);
}

void watch_ui_apply_profile_v4(const omarchy_profile_v4_t *profile)
{
    if (profile == NULL) return;
    allowance_remaining = profile->allowance_remaining;
    allowance_window = profile->allowance_window;
    allowance_updated_at = profile->allowance_updated_at;
    allowance_resets_at = profile->allowance_resets_at;
    watch_ui_apply_profile_v3(&profile->base);
}

void watch_ui_apply_profile_v5(const omarchy_profile_v5_t *profile)
{
    if (!profile) return;
    weather_daily_expires_at = profile->weather_daily_expires_at;
    watch_ui_apply_profile_v4(&profile->base);
}

void watch_ui_apply_activity(uint8_t state, bool alert, bool sound)
{
    if (state > OMARCHY_ACTIVITY_FINISHED) {
        return;
    }
    const bool wake = alert && display_preview_allowed();
    bsp_display_lock(0);
    agent_activity_state = state;
    update_agent();
    if (wake) {
        wake_display_locked(DISPLAY_PREVIEW_TIMEOUT_MS);
    }
    bsp_display_unlock();
    if (alert) {
        watch_haptics_completion();
    }
    if (sound) {
        if (state == OMARCHY_ACTIVITY_FINISHED) {
            watch_sound_completion();
        } else {
            watch_sound_attention();
        }
    }
}

void watch_ui_set_connected(bool connected)
{
    bsp_display_lock(0);
    ble_connected = connected;
    if (face_visible && display_awake) {
        update_connection();
    }
    bsp_display_unlock();
}
