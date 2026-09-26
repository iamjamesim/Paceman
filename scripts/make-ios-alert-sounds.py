"""Render iPhone alert tones matching the locked watch note patterns.

The note timings/frequencies mirror watch_sound_pattern.h. Run this after a
deliberate watch sound change, and update the values here to match it.
"""
from pathlib import Path
import math
import struct
import wave


RATE = 22050
DESTINATION = Path(__file__).resolve().parents[1] / "ios/Resources/Sounds"
# (start ms, duration ms, frequency Hz, amplitude): watch_sound_pattern.h
SOUNDS = {
    "PacemanWorking.wav": (130, ((0, 110, 1536, 16000),)),
    "PacemanInput.wav": (380, ((0, 110, 2048, 18000), (235, 125, 2048, 19000))),
    "PacemanFinished.wav": (300, ((0, 90, 2048, 15000), (130, 140, 1536, 16000))),
    "PacemanFailed.wav": (310, ((0, 280, 1280, 18000),)),
}


def sample_at(index, notes):
    value = 0.0
    for start_ms, duration_ms, frequency, amplitude in notes:
        start = RATE * start_ms // 1000
        length = RATE * duration_ms // 1000
        position = index - start
        if position < 0 or position >= length:
            continue
        attack = min(1.0, position / (RATE / 500))
        release = min(1.0, (length - position) / (RATE / 40))
        phase = 2 * math.pi * frequency * position / RATE
        tone = (math.sin(phase) + 0.18 * math.sin(2 * phase)
                + 0.07 * math.sin(3 * phase))
        value += amplitude * attack * release * tone
    return max(-32768, min(32767, round(value)))


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name, (duration_ms, notes) in SOUNDS.items():
        with wave.open(str(DESTINATION / name), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(RATE)
            count = RATE * duration_ms // 1000
            output.writeframes(b"".join(struct.pack("<h", sample_at(i, notes))
                                        for i in range(count)))


if __name__ == "__main__":
    main()
