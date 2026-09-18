#pragma once

#include <stdint.h>

#include "esp_err.h"

/** Initialize the board's battery-backed PCF85063A real-time clock. */
esp_err_t watch_rtc_init(void);

/**
 * Read a trusted UTC Unix timestamp.
 *
 * Returns ESP_ERR_INVALID_STATE when the RTC oscillator-stop flag is set or
 * the calendar registers do not contain a plausible date.
 */
esp_err_t watch_rtc_get_time(int64_t *unix_time);

/** Set the RTC calendar from a UTC Unix timestamp. */
esp_err_t watch_rtc_set_time(int64_t unix_time);
