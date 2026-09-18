#include "watch_sound.h"
#include "watch_sound_pattern.h"

#include <stdatomic.h>
#include <stdint.h>

#include "bsp/esp-bsp.h"
#include "esp_codec_dev.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

enum {
    SAMPLE_RATE = 22050,
    OUTPUT_VOLUME = 60,
    BUFFER_SAMPLES = 128,
    ATTACK_SAMPLES = SAMPLE_RATE / 500,
    RELEASE_SAMPLES = SAMPLE_RATE / 40,
};

static const char *TAG = "watch_sound";
static atomic_bool sound_running = ATOMIC_VAR_INIT(false);
static atomic_uint pending_sounds = ATOMIC_VAR_INIT(0);
static atomic_uint pending_attention = ATOMIC_VAR_INIT(0);
static esp_codec_dev_handle_t speaker;

static const int16_t sine_table[32] = {
    0, 6393, 12539, 18204, 23170, 27245, 30273, 32137,
    32767, 32137, 30273, 27245, 23170, 18204, 12539, 6393,
    0, -6393, -12539, -18204, -23170, -27245, -30273, -32137,
    -32767, -32137, -30273, -27245, -23170, -18204, -12539, -6393,
};

static int32_t oscillator(uint16_t frequency, uint32_t position)
{
    const uint32_t phase_step = ((uint64_t)frequency << 32) / SAMPLE_RATE;
    return sine_table[(uint32_t)(position * phase_step) >> 27];
}

static int32_t note_sample(const alert_note_t *note, uint32_t sample)
{
    const uint32_t start = SAMPLE_RATE * note->start_ms / 1000;
    const uint32_t duration = SAMPLE_RATE * note->duration_ms / 1000;
    if (sample < start || sample >= start + duration) {
        return 0;
    }

    const uint32_t position = sample - start;
    const uint32_t remaining = duration - position;
    int64_t envelope = note->amplitude;
    if (position < ATTACK_SAMPLES) {
        envelope = envelope * position / ATTACK_SAMPLES;
    }
    if (remaining < RELEASE_SAMPLES) {
        envelope = envelope * remaining / RELEASE_SAMPLES;
    }

    const int32_t fundamental = oscillator(note->frequency, position);
    const int32_t second = oscillator(note->frequency * 2, position);
    const int32_t third = oscillator(note->frequency * 3, position);
    int32_t mixed = fundamental * envelope / 32767;
    mixed += second * envelope * 18 / 100 / 32767;
    mixed += third * envelope * 7 / 100 / 32767;
    return mixed;
}

static bool write_chime(bool attention)
{
    const uint32_t total = SAMPLE_RATE * 380 / 1000;
    int16_t samples[BUFFER_SAMPLES];
    const alert_note_t notes[] = {watch_sound_note(attention, 0), watch_sound_note(attention, 1)};

    for (uint32_t written = 0; written < total;) {
        uint32_t count = total - written;
        if (count > BUFFER_SAMPLES) {
            count = BUFFER_SAMPLES;
        }
        for (uint32_t index = 0; index < count; ++index) {
            int32_t mixed = 0;
            for (unsigned note = 0;
                    note < sizeof(notes) / sizeof(notes[0]); ++note) {
                mixed += note_sample(&notes[note], written + index);
            }
            if (mixed > INT16_MAX) {
                mixed = INT16_MAX;
            } else if (mixed < INT16_MIN) {
                mixed = INT16_MIN;
            }
            samples[index] = mixed;
        }
        if (esp_codec_dev_write(speaker, samples, count * sizeof(samples[0])) != 0) {
            return false;
        }
        written += count;
    }
    return true;
}

static void play_chime(bool attention)
{
    if (speaker == NULL) {
        speaker = bsp_audio_codec_speaker_init();
    }
    if (speaker == NULL) {
        ESP_LOGE(TAG, "Speaker initialization failed");
        return;
    }

    esp_codec_dev_sample_info_t format = {
        .bits_per_sample = 16,
        .channel = 1,
        .sample_rate = SAMPLE_RATE,
    };
    if (esp_codec_dev_open(speaker, &format) != 0) {
        ESP_LOGE(TAG, "Could not open speaker codec");
        return;
    }
    if (esp_codec_dev_set_out_vol(speaker, OUTPUT_VOLUME) != 0) {
        ESP_LOGE(TAG, "Could not set speaker volume");
        esp_codec_dev_close(speaker);
        return;
    }
    /* Give the codec and amplifier time to leave mute before a short alert. */
    vTaskDelay(pdMS_TO_TICKS(100));

    if (!write_chime(attention)) {
        ESP_LOGE(TAG, "Could not write agent chime");
    }
    esp_codec_dev_close(speaker);
}

static void sound_worker(void *argument)
{
    (void)argument;
    for (;;) {
        /* Preserve each pending sound's kind; prioritize attention within a
         * batch rather than letting the latest state overwrite queued alerts. */
        unsigned attention_count = atomic_exchange(&pending_attention, 0);
        unsigned count = atomic_exchange(&pending_sounds, 0);
        while (attention_count-- > 0) {
            play_chime(true);
        }
        while (count-- > 0) {
            play_chime(false);
        }

        atomic_store(&sound_running, false);
        if ((atomic_load(&pending_sounds) == 0 && atomic_load(&pending_attention) == 0) ||
                atomic_exchange(&sound_running, true)) {
            break;
        }
    }
    vTaskDelete(NULL);
}

static void enqueue_sound(bool attention)
{
    atomic_fetch_add(attention ? &pending_attention : &pending_sounds, 1);
    if (atomic_exchange(&sound_running, true)) {
        return;
    }
    if (xTaskCreate(sound_worker, "watch_sound", 4096, NULL, 4, NULL) != pdPASS) {
        ESP_LOGE(TAG, "Could not create agent sound task");
        atomic_store(&pending_sounds, 0);
        atomic_store(&pending_attention, 0);
        atomic_store(&sound_running, false);
    }
}

void watch_sound_completion(void)
{
    enqueue_sound(false);
}

void watch_sound_attention(void)
{
    enqueue_sound(true);
}
