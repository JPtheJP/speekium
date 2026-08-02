#!/usr/bin/env python3
"""Feed a wav file through voxmlx's REAL mic-streaming code path by faking
sounddevice.InputStream. Lets us A/B the streaming decoder on known audio.

Usage: stream_from_file.py <wav> [--no-eos-reset] [--speed N]
"""
import sys, time, wave, threading, _thread
import numpy as np

import voxmlx.stream as vs
from voxmlx.audio import SAMPLES_PER_TOKEN

wav_path = sys.argv[1]
no_eos_reset = "--no-eos-reset" in sys.argv
speed = 20.0 if "--fast" in sys.argv else 1.0

with wave.open(wav_path, "rb") as w:
    assert w.getframerate() == 16000 and w.getnchannels() == 1
    pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
audio = (pcm.astype(np.float32) / 32768.0)


class FakeInputStream:
    """Replays `audio` into the callback in blocksize chunks, then interrupts."""

    def __init__(self, samplerate, channels, dtype, blocksize, callback):
        self.blocksize = blocksize
        self.callback = callback
        self._stop = threading.Event()

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        bs = self.blocksize
        for i in range(0, len(audio), bs):
            if self._stop.is_set():
                return
            chunk = audio[i:i + bs]
            if len(chunk) < bs:
                chunk = np.pad(chunk, (0, bs - len(chunk)))
            self.callback(chunk.reshape(-1, 1), bs, None, None)
            time.sleep((bs / 16000.0) / speed)
        time.sleep(1.0 / speed)
        _thread.interrupt_main()

    def stop(self):
        self._stop.set()

    def close(self):
        self._stop.set()


class FakeSD:
    InputStream = FakeInputStream


vs.sd = FakeSD

if no_eos_reset:
    _orig_load = vs.load_model

    def _patched_load(path):
        model, sp, config = _orig_load(path)

        class NoEOS:
            def __getattr__(self, n):
                return getattr(sp, n)

            @property
            def eos_id(self):
                return -12345  # never emitted -> cache never reset

        return model, NoEOS(), config

    vs.load_model = _patched_load

label = "NO-EOS-RESET" if no_eos_reset else "STOCK"
print(f"=== streaming decode [{label}] on {wav_path} ===", flush=True)
try:
    vs.stream_transcribe(model_path="models/voxtral-6bit", temperature=0.0)
except KeyboardInterrupt:
    pass
print("\n=== end ===", flush=True)
