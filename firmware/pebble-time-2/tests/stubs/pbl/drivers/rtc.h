/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <time.h>
typedef struct {
  int timezone_id, tm_gmtoff;
} TimezoneInfo;
void rtc_set_timezone(TimezoneInfo *);

time_t rtc_get_time(void);

#include <stdint.h>
typedef uint64_t RtcTicks;
#define RTC_TICKS_HZ 1000u
RtcTicks rtc_get_ticks(void);
