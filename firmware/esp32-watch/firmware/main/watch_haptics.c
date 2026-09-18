#include "watch_haptics.h"

#include <stdatomic.h>

#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

/* The board's motor driver enable is active-high on GPIO18. */
#define WATCH_MOTOR_GPIO GPIO_NUM_18

static atomic_bool pulse_running = ATOMIC_VAR_INIT(false);

static void completion_pulse(void *argument)
{
    (void)argument;
    gpio_set_level(WATCH_MOTOR_GPIO, 1);
    vTaskDelay(pdMS_TO_TICKS(80));
    gpio_set_level(WATCH_MOTOR_GPIO, 0);
    vTaskDelay(pdMS_TO_TICKS(90));
    gpio_set_level(WATCH_MOTOR_GPIO, 1);
    vTaskDelay(pdMS_TO_TICKS(80));
    gpio_set_level(WATCH_MOTOR_GPIO, 0);
    atomic_store(&pulse_running, false);
    vTaskDelete(NULL);
}

esp_err_t watch_haptics_start(void)
{
    const gpio_config_t config = {
        .pin_bit_mask = 1ULL << WATCH_MOTOR_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    esp_err_t error = gpio_config(&config);
    if (error == ESP_OK) {
        error = gpio_set_level(WATCH_MOTOR_GPIO, 0);
    }
    return error;
}

void watch_haptics_completion(void)
{
    if (atomic_exchange(&pulse_running, true)) {
        return;
    }
    if (xTaskCreate(completion_pulse, "watch_haptic", 2048, NULL, 4, NULL) != pdPASS) {
        atomic_store(&pulse_running, false);
    }
}
