"""Generate small, original synthetic foil/card cues; no third-party recordings."""
import math
import random
import struct
import wave
from pathlib import Path

out = Path(__file__).resolve().parents[1] / 'app/assets/audio'
out.mkdir(parents=True, exist_ok=True)
rng = random.Random(42)
for name, duration in [('grip', .16), ('tear', .29), ('brush', .21), ('square', .075)]:
    frames = []
    prev = 0
    for i in range(int(22050 * duration)):
        t = i / 22050
        noise = rng.uniform(-1, 1)
        high = noise - prev
        prev = noise
        if name == 'square':
            value = (.55 * math.sin(2 * math.pi * 840 * t) + .3 * noise) * math.exp(-t * 85)
        elif name == 'brush':
            value = .13 * high * math.sin(math.pi * t / duration) ** 2
        else:
            pulses = (.4 + .6 * math.sin(t * (167 if name == 'tear' else 98)) ** 8)
            value = .26 * high * pulses * math.sin(math.pi * t / duration)
        frames.append(struct.pack('<h', int(max(-1, min(1, value)) * 32767)))
    with wave.open(str(out / f'{name}.wav'), 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(22050)
        f.writeframes(b''.join(frames))
