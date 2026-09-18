#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    bool battery_present;
    bool charging;
    bool external_power;
    uint8_t percent;
} watch_power_state_t;

/** Initialize read-only access to the board's AXP2101 power manager. */
esp_err_t watch_power_init(void);

/** Read the current battery and external-power state. */
esp_err_t watch_power_read(watch_power_state_t *state);
