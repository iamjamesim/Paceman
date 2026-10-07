/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
typedef struct { uint8_t midi_note, waveform; uint16_t duration_ms; } SpeakerNote;
enum { SpeakerWaveformSine, SpeakerPriorityNotification };
bool speaker_service_play_note_seq(const SpeakerNote *notes, uint32_t count, int priority, uint8_t volume);
