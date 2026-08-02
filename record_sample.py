#!/usr/bin/env python3
"""Record a mic sample for ASR testing. Usage: record_sample.py [seconds] [outfile]"""
import sys
import sounddevice as sd
import numpy as np
import wave

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0
out = sys.argv[2] if len(sys.argv) > 2 else "sample.wav"
sr = 16000

print(f"Recording {secs:.0f}s at {sr} Hz — speak now (mixed zh/en, the way you normally talk)...")
audio = sd.rec(int(secs * sr), samplerate=sr, channels=1, dtype="int16")
sd.wait()

with wave.open(out, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(audio.tobytes())

peak = np.abs(audio).max() / 32768.0
rms = np.sqrt((audio.astype(np.float32) ** 2).mean()) / 32768.0
print(f"Saved {out}")
print(f"  peak={peak:.3f}  rms={rms:.4f}")
if peak > 0.99:
    print("  WARNING: clipping — lower input gain")
elif peak < 0.1:
    print("  WARNING: very quiet — raise input gain or move closer")
