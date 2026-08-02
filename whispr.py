#!/usr/bin/env python3
"""whispr-stream — push-to-talk dictation for macOS with zh/en code-switching.

Hold the hotkey, speak, release. Text is transcribed locally with Qwen3-ASR
and inserted at the cursor.

The model is loaded once at startup and stays resident — that is what turns a
~6s cold transcribe into ~0.7s. Never reload per utterance.

Usage:
    python whispr.py [--model ...] [--key right_option] [--list-devices]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import threading
import time

import numpy as np
import sounddevice as sd
from pynput import keyboard

SAMPLE_RATE = 16000
MIN_SECONDS = 0.3  # ignore accidental taps

KEY_ALIASES = {
    "right_option": keyboard.Key.alt_r,
    "left_option": keyboard.Key.alt_l,
    "right_cmd": keyboard.Key.cmd_r,
    "right_ctrl": keyboard.Key.ctrl_r,
    "right_shift": keyboard.Key.shift_r,
    "f5": keyboard.Key.f5,
    "f6": keyboard.Key.f6,
    "f13": keyboard.Key.f13,
}


class Recorder:
    """Accumulates mic audio between press and release."""

    def __init__(self, device=None):
        self._chunks: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._stream: sd.InputStream | None = None
        self.device = device

    def _callback(self, indata, frames, time_info, status):
        with self._lock:
            self._chunks.append(indata[:, 0].copy())

    def start(self):
        with self._lock:
            self._chunks = []
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=1,
            dtype="float32",
            device=self.device,
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        with self._lock:
            if not self._chunks:
                return np.zeros(0, dtype=np.float32)
            return np.concatenate(self._chunks)


def insert_text(text: str) -> None:
    """Insert text at the cursor via pasteboard + Cmd-V.

    Synthetic per-character keystrokes are unreliable for CJK; the pasteboard
    round-trip handles mixed scripts correctly. The previous clipboard is
    restored, but only its plain-text content.
    """
    try:
        prev = subprocess.run(
            ["pbpaste"], capture_output=True, text=True, timeout=2
        ).stdout
    except Exception:
        prev = None

    subprocess.run(["pbcopy"], input=text, text=True, check=True)

    ctrl = keyboard.Controller()
    with ctrl.pressed(keyboard.Key.cmd):
        ctrl.press("v")
        ctrl.release("v")

    if prev is not None:
        # Let the paste land before clobbering the pasteboard again.
        def restore():
            time.sleep(0.6)
            try:
                subprocess.run(["pbcopy"], input=prev, text=True, timeout=2)
            except Exception:
                pass

        threading.Thread(target=restore, daemon=True).start()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default="Qwen/Qwen3-ASR-0.6B")
    ap.add_argument("--key", default="right_option", choices=sorted(KEY_ALIASES))
    ap.add_argument("--device", default=None, help="input device name or index")
    ap.add_argument("--list-devices", action="store_true")
    ap.add_argument(
        "--no-insert",
        action="store_true",
        help="print the transcript instead of inserting it",
    )
    ap.add_argument(
        "--context",
        default=None,
        help="space-separated domain terms to bias decoding (e.g. technical jargon)",
    )
    ap.add_argument(
        "--bits", type=int, default=8,
        help="quantization bits: 8 (default, 2.4x faster, no quality loss), "
             "4 (degrades code-switching), 0 (fp16)",
    )
    args = ap.parse_args()

    if args.list_devices:
        print(sd.query_devices())
        return 0

    device = args.device
    if device is not None and device.isdigit():
        device = int(device)

    hotkey = KEY_ALIASES[args.key]

    print(f"loading {args.model} ({args.bits or 'fp16'}-bit) ...", flush=True)
    from asr_engine import build_session

    session, load_secs = build_session(args.model, args.bits)
    print(f"ready in {load_secs:.1f}s", flush=True)
    print(f"hold [{args.key}] to dictate, ctrl-c to quit\n", flush=True)

    recorder = Recorder(device=device)
    state = {"recording": False, "busy": False}

    def on_press(key):
        if key != hotkey or state["recording"] or state["busy"]:
            return
        state["recording"] = True
        print("● recording", end="", flush=True)
        recorder.start()

    def on_release(key):
        if key != hotkey or not state["recording"]:
            return
        state["recording"] = False
        state["busy"] = True
        try:
            audio = recorder.stop()
            secs = len(audio) / SAMPLE_RATE
            if secs < MIN_SECONDS:
                print(f"\r  (too short: {secs:.2f}s)      ", flush=True)
                return

            t = time.time()
            kw = {"context": args.context} if args.context else {}
            result = session.transcribe(audio, **kw)
            text = (getattr(result, "text", None) or str(result)).strip()
            dt = time.time() - t

            if not text:
                print(f"\r  (no speech in {secs:.1f}s)      ", flush=True)
                return

            print(f"\r  {secs:.1f}s audio → {dt:.2f}s  {text}", flush=True)
            if not args.no_insert:
                insert_text(text)
        except Exception as e:  # keep the daemon alive across bad utterances
            print(f"\r  error: {e}", flush=True)
        finally:
            state["busy"] = False

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        try:
            listener.join()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
