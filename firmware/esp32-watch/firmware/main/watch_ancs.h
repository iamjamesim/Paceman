#pragma once

#include <stdint.h>
#include "host/ble_gap.h"

/* ANCS runs as a GATT client on the existing encrypted phone connection.
 * Callback means a Paceman notification changed, not that its state is known. */
void watch_ancs_init(void (*changed)(void));
void watch_ancs_connected(uint16_t connection);
void watch_ancs_disconnected(uint16_t connection);
void watch_ancs_received(const struct ble_gap_event *event);
