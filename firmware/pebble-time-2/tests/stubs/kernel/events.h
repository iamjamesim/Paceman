/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#define PEBBLE_PACEMAN_EVENT 1
typedef struct {
  int type;
} PebbleEvent;
void event_put(PebbleEvent *);
