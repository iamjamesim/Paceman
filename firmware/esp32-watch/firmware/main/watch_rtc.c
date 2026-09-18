#include "watch_rtc.h"

#include <stdbool.h>
#include <stddef.h>
#include <time.h>

#include "bsp/esp-bsp.h"
#include "pcf85063a.h"

enum {
    RTC_OSCILLATOR_STOP = 1 << 7,
    EARLIEST_TRUSTED_YEAR = 2024,
    LATEST_SUPPORTED_YEAR = 2069,
};

static pcf85063a_dev_t rtc;
static bool initialized;

static bool is_leap_year(int year)
{
    return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

static int days_in_month(int year, int month)
{
    static const uint8_t lengths[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (month == 2 && is_leap_year(year)) {
        return 29;
    }
    return lengths[month - 1];
}

/* Howard Hinnant's civil-calendar conversion, with 1970-01-01 as day zero. */
static int64_t unix_from_calendar(const pcf85063a_datetime_t *calendar)
{
    int year = calendar->year;
    const unsigned month = calendar->month;
    const unsigned day = calendar->day;
    year -= month <= 2;
    const int era = (year >= 0 ? year : year - 399) / 400;
    const unsigned year_of_era = (unsigned)(year - era * 400);
    const unsigned adjusted_month = month > 2 ? month - 3 : month + 9;
    const unsigned day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    const unsigned day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    const int64_t days = (int64_t)era * 146097 + day_of_era - 719468;
    return days * 86400 + calendar->hour * 3600 + calendar->min * 60 + calendar->sec;
}

static bool calendar_is_valid(const pcf85063a_datetime_t *calendar)
{
    return calendar->year >= EARLIEST_TRUSTED_YEAR &&
           calendar->year <= LATEST_SUPPORTED_YEAR &&
           calendar->month >= 1 && calendar->month <= 12 &&
           calendar->day >= 1 && calendar->day <= days_in_month(calendar->year, calendar->month) &&
           calendar->hour <= 23 && calendar->min <= 59 && calendar->sec <= 59;
}

esp_err_t watch_rtc_init(void)
{
    if (initialized) {
        return ESP_OK;
    }
    esp_err_t err = pcf85063a_init(&rtc, bsp_i2c_get_handle(), PCF85063A_ADDRESS);
    if (err == ESP_OK) {
        initialized = true;
    }
    return err;
}

esp_err_t watch_rtc_get_time(int64_t *unix_time)
{
    if (unix_time == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    uint8_t seconds;
    esp_err_t err = pcf85063a_read_register(
        &rtc, PCF85063A_RTC_SECOND_ADDR, &seconds, sizeof(seconds)
    );
    if (err != ESP_OK) {
        return err;
    }
    if ((seconds & RTC_OSCILLATOR_STOP) != 0) {
        return ESP_ERR_INVALID_STATE;
    }

    pcf85063a_datetime_t calendar;
    err = pcf85063a_get_time_date(&rtc, &calendar);
    if (err != ESP_OK) {
        return err;
    }
    if (!calendar_is_valid(&calendar)) {
        return ESP_ERR_INVALID_STATE;
    }

    *unix_time = unix_from_calendar(&calendar);
    return ESP_OK;
}

esp_err_t watch_rtc_set_time(int64_t unix_time)
{
    if (!initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    time_t timestamp = (time_t)unix_time;
    struct tm utc;
    if (gmtime_r(&timestamp, &utc) == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    const int year = utc.tm_year + 1900;
    if (year < EARLIEST_TRUSTED_YEAR || year > LATEST_SUPPORTED_YEAR) {
        return ESP_ERR_INVALID_ARG;
    }

    const pcf85063a_datetime_t calendar = {
        .year = (uint16_t)year,
        .month = (uint8_t)(utc.tm_mon + 1),
        .day = (uint8_t)utc.tm_mday,
        .dotw = (uint8_t)utc.tm_wday,
        .hour = (uint8_t)utc.tm_hour,
        .min = (uint8_t)utc.tm_min,
        .sec = (uint8_t)utc.tm_sec,
    };
    return pcf85063a_set_time_date(&rtc, calendar);
}
