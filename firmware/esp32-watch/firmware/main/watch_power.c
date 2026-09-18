#include "watch_power.h"

#include <stddef.h>

#include "bsp/esp-bsp.h"
#include "driver/i2c_master.h"

enum {
    AXP2101_ADDRESS = 0x34,
    AXP2101_REG_STATUS1 = 0x00,
    AXP2101_REG_STATUS2 = 0x01,
    AXP2101_REG_CHIP_ID = 0x03,
    AXP2101_REG_BATTERY_PERCENT = 0xA4,
    AXP2101_CHIP_ID = 0x4A,
    AXP2101_STATUS1_VBUS_GOOD = 1 << 5,
    AXP2101_STATUS1_BATTERY_PRESENT = 1 << 3,
    AXP2101_STATUS2_CHARGE_SHIFT = 5,
    AXP2101_STATUS2_CHARGING = 1,
    I2C_TIMEOUT_MS = 100,
};

static i2c_master_dev_handle_t power_device;

static esp_err_t read_register(uint8_t address, uint8_t *value)
{
    return i2c_master_transmit_receive(
        power_device, &address, sizeof(address), value, sizeof(*value), I2C_TIMEOUT_MS
    );
}

esp_err_t watch_power_init(void)
{
    if (power_device != NULL) {
        return ESP_OK;
    }

    const i2c_device_config_t config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = AXP2101_ADDRESS,
        .scl_speed_hz = 400000,
    };
    esp_err_t err = i2c_master_bus_add_device(
        bsp_i2c_get_handle(), &config, &power_device
    );
    if (err != ESP_OK) {
        power_device = NULL;
        return err;
    }

    uint8_t chip_id;
    err = read_register(AXP2101_REG_CHIP_ID, &chip_id);
    if (err != ESP_OK || chip_id != AXP2101_CHIP_ID) {
        i2c_master_bus_rm_device(power_device);
        power_device = NULL;
        return err == ESP_OK ? ESP_ERR_NOT_FOUND : err;
    }
    return ESP_OK;
}

esp_err_t watch_power_read(watch_power_state_t *state)
{
    if (state == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (power_device == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    uint8_t status1;
    uint8_t status2;
    esp_err_t err = read_register(AXP2101_REG_STATUS1, &status1);
    if (err == ESP_OK) {
        err = read_register(AXP2101_REG_STATUS2, &status2);
    }
    if (err != ESP_OK) {
        return err;
    }

    *state = (watch_power_state_t) {
        .battery_present = (status1 & AXP2101_STATUS1_BATTERY_PRESENT) != 0,
        .charging = (status2 >> AXP2101_STATUS2_CHARGE_SHIFT) ==
                    AXP2101_STATUS2_CHARGING,
        .external_power = (status1 & AXP2101_STATUS1_VBUS_GOOD) != 0,
        .percent = 0,
    };
    if (!state->battery_present) {
        return ESP_OK;
    }

    err = read_register(AXP2101_REG_BATTERY_PERCENT, &state->percent);
    if (err != ESP_OK) {
        return err;
    }
    if (state->percent > 100) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    return ESP_OK;
}
