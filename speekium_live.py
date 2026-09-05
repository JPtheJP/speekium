#!/usr/bin/env python3
"""speekium (live) — push-to-talk dictation that shows text WHILE you speak.

Approach: Qwen3-ASR's own --streaming chunks the audio, and chunk boundaries land
mid-word, which wrecks zh/en code-switching. We don't chunk. At RTF ~0.057 we can
simply re-transcribe the ENTIRE utterance from scratch every few hundred ms, so
every pass sees full context and reads exactly like the offline result.

Stability uses LocalAgreement-2: a prefix is "committed" once two consecutive
passes agree on it. Committed text is shown plain, the still-changing tail dim.
Only the final full-context pass is inserted at the cursor.

Usage:
    python speekium_live.py                  # push-to-talk, hold right option
    python speekium_live.py --simulate x.wav # replay a wav, no mic needed
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import threading
import time
import wave

import numpy as np
import sounddevice as sd

SAMPLE_RATE = 16000
MIN_SECONDS = 0.3
POLL_INTERVAL = 0.02   # tiny yield; decode cost itself is the real pacing
MIN_NEW_AUDIO = 0.15   # skip a pass unless this much new audio arrived
MAX_BUFFER_SEC = 45.0  # re-decode cost grows with length; cap it

DIM, RESET = "\033[2m", "\033[0m"


def commonprefix(a: str, b: str) -> str:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return a[:i]


class LiveTranscriber:
    """Re-decodes the whole buffer repeatedly and tracks a stable prefix."""

    def __init__(self, session, context: str = ""):
        self.session = session
        self.context = context
        self.committed = ""
        self._prev = ""

    def reset(self) -> None:
        self.committed = ""
        self._prev = ""

    def update(self, audio: np.ndarray) -> tuple[str, str]:
        """Returns (committed, volatile_tail)."""
        kw = {"context": self.context} if self.context else {}
        text = (self.session.transcribe(audio, **kw).text or "").strip()
        # LocalAgreement-2: whatever two consecutive passes agree on is settled.
        agreed = commonprefix(text, self._prev)
        if len(agreed) > len(self.committed):
            self.committed = agreed
        self._prev = text
        return self.committed, text[len(self.committed):]


def render(committed: str, tail: str) -> None:
    cols = shutil_cols()
    line = f"{committed}{DIM}{tail}{RESET}"
    plain = committed + tail
    if len(plain) > cols - 4:
        keep = cols - 7
        plain_trim = plain[-keep:]
        cut = len(plain) - len(plain_trim)
        c = committed[cut:] if cut < len(committed) else ""
        t = tail if cut < len(committed) else plain_trim
        line = f"...{c}{DIM}{t}{RESET}"
    sys.stdout.write("\r\033[K  " + line)
    sys.stdout.flush()


def shutil_cols() -> int:
    try:
        return os.get_terminal_size().columns
    except OSError:
        return 100


def insert_text(text: str) -> None:
    from pynput import keyboard as kb

    try:
        prev = subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=2).stdout
    except Exception:
        prev = None
    subprocess.run(["pbcopy"], input=text, text=True, check=True)
    ctrl = kb.Controller()
    with ctrl.pressed(kb.Key.cmd):
        ctrl.press("v")
        ctrl.release("v")
    if prev is not None:
        def restore():
            time.sleep(0.6)
            try:
                subprocess.run(["pbcopy"], input=prev, text=True, timeout=2)
            except Exception:
                pass
        threading.Thread(target=restore, daemon=True).start()


class Engine:
    """Owns the audio buffer and the background re-decode loop."""

    def __init__(self, session, context: str):
        self.live = LiveTranscriber(session, context)
        self.lock = threading.Lock()
        self.buf = np.zeros(0, dtype=np.float32)
        self.active = False
        self._thread: threading.Thread | None = None

    def feed(self, chunk: np.ndarray) -> None:
        with self.lock:
            self.buf = np.append(self.buf, chunk)
            cap = int(MAX_BUFFER_SEC * SAMPLE_RATE)
            if len(self.buf) > cap:
                self.buf = self.buf[-cap:]

    def snapshot(self) -> np.ndarray:
        with self.lock:
            return self.buf.copy()

    def start(self) -> None:
        with self.lock:
            self.buf = np.zeros(0, dtype=np.float32)
        self.live.reset()
        self.active = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        last_len = 0
        while self.active:
            audio = self.snapshot()
            # Don't burn a pass on a buffer that has barely grown.
            grew = len(audio) - last_len >= int(MIN_NEW_AUDIO * SAMPLE_RATE)
            if len(audio) < int(MIN_SECONDS * SAMPLE_RATE) or not grew:
                time.sleep(POLL_INTERVAL)
                continue
            last_len = len(audio)
            try:
                committed, tail = self.live.update(audio)
                if self.active:
                    render(committed, tail)
            except Exception:
                pass
            time.sleep(POLL_INTERVAL)

    def finish(self) -> tuple[str, float, float]:
        self.active = False
        if self._thread is not None:
            self._thread.join(timeout=5.0)
        audio = self.snapshot()
        secs = len(audio) / SAMPLE_RATE
        if secs < MIN_SECONDS:
            return "", secs, 0.0
        t = time.time()
        kw = {"context": self.live.context} if self.live.context else {}
        text = (self.live.session.transcribe(audio, **kw).text or "").strip()
        return text, secs, time.time() - t


def run_simulate(engine: Engine, path: str) -> int:
    with wave.open(path, "rb") as w:
        assert w.getframerate() == SAMPLE_RATE and w.getnchannels() == 1
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    audio = pcm.astype(np.float32) / 32768.0
    print(f"simulating {len(audio)/SAMPLE_RATE:.1f}s of audio in real time\n")
    engine.start()
    block = int(0.1 * SAMPLE_RATE)
    for i in range(0, len(audio), block):
        engine.feed(audio[i:i + block])
        time.sleep(0.1)
    text, secs, dt = engine.finish()
    print(f"\n\nfinal ({secs:.1f}s audio, {dt:.2f}s): {text}")
    return 0


def run_ptt(engine: Engine, key_name: str, no_insert: bool, device) -> int:
    from pynput import keyboard as kb

    aliases = {
        "right_option": kb.Key.alt_r, "left_option": kb.Key.alt_l,
        "right_cmd": kb.Key.cmd_r, "right_ctrl": kb.Key.ctrl_r,
        "f5": kb.Key.f5, "f13": kb.Key.f13,
    }
    hotkey = aliases[key_name]
    state = {"on": False, "busy": False}
    stream = {"s": None}

    def cb(indata, frames, tinfo, status):
        engine.feed(indata[:, 0].copy())

    def on_press(k):
        if k != hotkey or state["on"] or state["busy"]:
            return
        state["on"] = True
        print("● ", end="", flush=True)
        engine.start()
        stream["s"] = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype="float32",
            device=device, callback=cb,
        )
        stream["s"].start()

    def on_release(k):
        if k != hotkey or not state["on"]:
            return
        state["on"] = False
        state["busy"] = True
        try:
            if stream["s"] is not None:
                stream["s"].stop()
                stream["s"].close()
                stream["s"] = None
            text, secs, dt = engine.finish()
            if not text:
                print(f"\r\033[K  (nothing in {secs:.1f}s)", flush=True)
                return
            print(f"\r\033[K  {secs:.1f}s → {dt:.2f}s  {text}", flush=True)
            if not no_insert:
                insert_text(text)
        except Exception as e:
            print(f"\r\033[K  error: {e}", flush=True)
        finally:
            state["busy"] = False

    print(f"hold [{key_name}] to dictate, ctrl-c to quit\n")
    with kb.Listener(on_press=on_press, on_release=on_release) as l:
        try:
            l.join()
        except KeyboardInterrupt:
            pass
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default="Qwen/Qwen3-ASR-0.6B")
    ap.add_argument("--key", default="right_option")
    ap.add_argument("--device", default=None)
    ap.add_argument("--context", default="")
    ap.add_argument("--no-insert", action="store_true")
    ap.add_argument("--simulate", default=None, help="replay a 16k mono wav instead of the mic")
    ap.add_argument(
        "--bits", type=int, default=8,
        help="quantization bits: 8 (default, 2.4x faster, no quality loss), "
             "4 (marginally faster, degrades code-switching), 0 (fp16)",
    )
    args = ap.parse_args()

    device = int(args.device) if (args.device or "").isdigit() else args.device

    print(f"loading {args.model} ({args.bits or 'fp16'}-bit) ...", flush=True)
    from asr_engine import build_session

    session, load_secs = build_session(args.model, args.bits)
    print(f"ready in {load_secs:.1f}s", flush=True)

    engine = Engine(session, args.context)
    if args.simulate:
        return run_simulate(engine, args.simulate)
    return run_ptt(engine, args.key, args.no_insert, device)


if __name__ == "__main__":
    sys.exit(main())
