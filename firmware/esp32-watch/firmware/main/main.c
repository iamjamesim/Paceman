#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_pm.h"
#include "esp_random.h"
#include "nvs.h"
#include "nvs_flash.h"

#include "watch_ble.h"
#include "watch_haptics.h"
#include "watch_power.h"
#include "watch_profile.h"
#include "watch_rtc.h"
#include "watch_ui.h"

#if !CONFIG_PM_ENABLE
#error "Omarchy Watch requires CONFIG_PM_ENABLE for dynamic power management"
#endif

#if !CONFIG_FREERTOS_USE_TICKLESS_IDLE
#error "Omarchy Watch requires CONFIG_FREERTOS_USE_TICKLESS_IDLE"
#endif

#if !CONFIG_BT_CTRL_MODEM_SLEEP
#error "Omarchy Watch requires CONFIG_BT_CTRL_MODEM_SLEEP"
#endif

static const char *TAG = "omarchy_watch";

static esp_err_t initialize_nvs(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    return err;
}

static bool load_owned_state(void)
{
    nvs_handle_t nvs;
    if (nvs_open("omarchy", NVS_READONLY, &nvs) != ESP_OK) {
        return false;
    }

    uint8_t owned = 0;
    esp_err_t err = nvs_get_u8(nvs, "owned", &owned);
    nvs_close(nvs);
    return err == ESP_OK && owned == 1;
}

static bool load_cached_profile(omarchy_profile_v1_t *profile)
{
    nvs_handle_t nvs;
    if (nvs_open("omarchy", NVS_READONLY, &nvs) != ESP_OK) {
        return false;
    }

    size_t length = sizeof(*profile);
    esp_err_t err = nvs_get_blob(nvs, "profile_v1", profile, &length);
    nvs_close(nvs);
    return err == ESP_OK && length == sizeof(*profile) &&
           omarchy_profile_v1_is_valid(profile);
}

static bool load_cached_profile_v2(omarchy_profile_v2_t *profile)
{
    nvs_handle_t nvs;
    if (nvs_open("omarchy", NVS_READONLY, &nvs) != ESP_OK) {
        return false;
    }

    size_t length = sizeof(*profile);
    esp_err_t err = nvs_get_blob(nvs, "profile_v2", profile, &length);
    nvs_close(nvs);
    return err == ESP_OK && length == sizeof(*profile) &&
           omarchy_profile_v2_is_valid(profile);
}

static bool load_cached_profile_v5(omarchy_profile_v5_t *profile)
{
    nvs_handle_t nvs;
    if (nvs_open("omarchy", NVS_READONLY, &nvs) != ESP_OK) return false;
    size_t length = sizeof(*profile);
    esp_err_t err = nvs_get_blob(nvs, "profile_v5", profile, &length);
    nvs_close(nvs);
    return err == ESP_OK && length == sizeof(*profile) && omarchy_profile_v5_is_valid(profile);
}

static bool load_cached_profile_v4(omarchy_profile_v4_t *profile)
{
    nvs_handle_t nvs;
    if (nvs_open("omarchy", NVS_READONLY, &nvs) != ESP_OK) return false;
    size_t length = sizeof(*profile);
    esp_err_t err = nvs_get_blob(nvs, "profile_v4", profile, &length);
    nvs_close(nvs);
    return err == ESP_OK && length == sizeof(*profile) && omarchy_profile_v4_is_valid(profile);
}

static bool load_cached_profile_v3(omarchy_profile_v3_t *profile)
{
    nvs_handle_t nvs;
    if (nvs_open("omarchy", NVS_READONLY, &nvs) != ESP_OK) {
        return false;
    }

    size_t length = sizeof(*profile);
    esp_err_t err = nvs_get_blob(nvs, "profile_v3", profile, &length);
    nvs_close(nvs);
    return err == ESP_OK && length == sizeof(*profile) &&
           omarchy_profile_v3_is_valid(profile);
}

void app_main(void)
{
    ESP_ERROR_CHECK(initialize_nvs());

    const esp_pm_config_t power_config = {
        .max_freq_mhz = 160,
        .min_freq_mhz = 40,
        .light_sleep_enable = true,
    };
    ESP_ERROR_CHECK(esp_pm_configure(&power_config));

    const bool owned = load_owned_state();
    const uint32_t passkey = owned ? 0 : 100000 + (esp_random() % 900000);

    ESP_ERROR_CHECK(watch_ui_start());
    ESP_ERROR_CHECK(watch_haptics_start());
    esp_err_t power_err = watch_power_init();
    if (power_err != ESP_OK) {
        ESP_LOGW(TAG, "Battery telemetry unavailable: %s",
                 esp_err_to_name(power_err));
    }
    esp_err_t rtc_err = watch_rtc_init();
    if (rtc_err != ESP_OK) {
        ESP_LOGW(TAG, "RTC unavailable: %s", esp_err_to_name(rtc_err));
    }

    if (owned) {
        omarchy_profile_v5_t cached_profile_v5;
        omarchy_profile_v4_t cached_profile_v4;
        omarchy_profile_v3_t cached_profile_v3;
        omarchy_profile_v2_t cached_profile_v2;
        omarchy_profile_v1_t cached_profile;
        int64_t rtc_time;
        if (load_cached_profile_v5(&cached_profile_v5) &&
            watch_rtc_get_time(&rtc_time) == ESP_OK &&
            rtc_time >= cached_profile_v5.base.base.unix_time) {
            cached_profile_v5.base.base.unix_time = rtc_time;
            watch_ui_apply_profile_v5(&cached_profile_v5);
            ESP_LOGI(TAG, "Restored trusted time and v5 profile from RTC");
        } else if (load_cached_profile_v4(&cached_profile_v4) &&
            watch_rtc_get_time(&rtc_time) == ESP_OK &&
            rtc_time >= cached_profile_v4.base.unix_time) {
            cached_profile_v4.base.unix_time = rtc_time;
            watch_ui_apply_profile_v4(&cached_profile_v4);
            ESP_LOGI(TAG, "Restored trusted time and v4 profile from RTC");
        } else if (load_cached_profile_v3(&cached_profile_v3) &&
            watch_rtc_get_time(&rtc_time) == ESP_OK &&
            rtc_time >= cached_profile_v3.unix_time) {
            cached_profile_v3.unix_time = rtc_time;
            watch_ui_apply_profile_v3(&cached_profile_v3);
            ESP_LOGI(TAG, "Restored trusted time and v3 profile from RTC");
        } else if (load_cached_profile_v2(&cached_profile_v2) &&
            watch_rtc_get_time(&rtc_time) == ESP_OK &&
            rtc_time >= cached_profile_v2.unix_time) {
            cached_profile_v2.unix_time = rtc_time;
            watch_ui_apply_profile_v2(&cached_profile_v2);
            ESP_LOGI(TAG, "Restored trusted time and v2 profile from RTC");
        } else if (load_cached_profile(&cached_profile) &&
            watch_rtc_get_time(&rtc_time) == ESP_OK &&
            rtc_time >= cached_profile.unix_time) {
            watch_ui_apply_time(
                rtc_time, cached_profile.utc_offset_minutes, cached_profile.hour_cycle
            );
            ESP_LOGI(TAG, "Restored trusted time from RTC");
        } else {
            watch_ui_show_time_unavailable();
            ESP_LOGW(TAG, "Waiting for desktop time synchronization");
        }
    } else {
        watch_ui_show_pairing(passkey);
    }

    esp_err_t err = watch_ble_start(passkey, owned);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Bluetooth startup failed: %s", esp_err_to_name(err));
        watch_ui_show_error("BLUETOOTH UNAVAILABLE");
    }
}
