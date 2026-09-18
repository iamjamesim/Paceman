#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t watch_ble_start(uint32_t pairing_passkey, bool owned);
void watch_ble_acknowledge_activity(void);
