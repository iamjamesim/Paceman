/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <time.h>
typedef struct {
  int timezone_id, tm_gmtoff;
} TimezoneInfo;
void rtc_set_timezone(TimezoneInfo *);
