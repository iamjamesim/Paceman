/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <time.h>
#include <stdint.h>
void clock_set_24h_style(bool);
void clock_set_time(time_t);
void clock_set_time_with_utc_offset(time_t, int16_t);
