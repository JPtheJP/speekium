#!/usr/bin/env python3
"""ASR sidecar for the WhisprStream macOS app.

Speaks newline-delimited JSON on stdin/stdout so Swift can drive it:

    in : {"cmd":"start"}
         {"cmd":"audio","pcm":"<base64 int16 mono 16k>"}
         {"cmd":"stop"}
    out: {"type":"ready","ms":850}
         {"type":"partial","committed":"...","tail":"..."}
         {"type":"final","text":"...","secs":2.6,"ms":140}
         {"type":"error","message":"..."}

Inference strategy is the one we measured: never chunk. Re-decode the whole
utterance every pass (RTF ~0.024 at 8-bit) so every pass has full context and
zh/en code-switching survives. LocalAgreement-2 marks a prefix stable once two
consecutive passes agree.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import threading
import time

import numpy as np

SAMPLE_RATE = 16000
MIN_SECONDS = 0.3
POLL_INTERVAL = 0.02
MIN_NEW_AUDIO = 0.15
# Swift stops dictation at 45 seconds. Keep several seconds of transport/timer
# headroom so the rolling buffer can never trim the beginning before that stop
# command reaches the sidecar.
MAX_BUFFER_SEC = 50.0

# A completed preview may be reused when the only audio it has not seen is a
# short, confidently silent tail. These thresholds are deliberately
# conservative: ordinary room noise passes, while even quiet speech or a sharp
# transient falls back to the authoritative final decode.
MAX_SILENT_REUSE_TAIL = 0.75
SILENCE_WINDOW_SEC = 0.02
SILENCE_MAX_WINDOW_RMS = 0.02
SILENCE_MAX_PEAK = 0.06


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def commonprefix(a: str, b: str) -> str:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return a[:i]


def is_confident_silence(audio: np.ndarray) -> bool:
    """Return True only when every short window looks safely non-speech."""
    if len(audio) == 0:
        return True
    if float(np.max(np.abs(audio))) > SILENCE_MAX_PEAK:
        return False

    window = max(1, int(SILENCE_WINDOW_SEC * SAMPLE_RATE))
    for start in range(0, len(audio), window):
        frame = audio[start:start + window]
        rms = float(np.sqrt(np.mean(frame * frame)))
        if rms > SILENCE_MAX_WINDOW_RMS:
            return False
    return True


class Server:
    def __init__(self, model_id: str, bits: int, context: str):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from asr_engine import build_session

        self.session, load_secs = build_session(model_id, bits)
        emit({"type": "ready", "ms": int(load_secs * 1000)})

        self.lock = threading.Lock()
        self.context = context
        self._context_revision = 0
        self.buf = np.zeros(0, dtype=np.float32)
        self.active = False
        self.committed = ""
        self._prev = ""
        self._last_preview_text: str | None = None
        self._last_preview_len = 0
        self._last_preview_context_revision = -1
        self._last_preview_stable = False
        self._thread: threading.Thread | None = None

    # -- transcription -------------------------------------------------
    def _decode(self, audio: np.ndarray, context: str) -> str:
        kw = {"context": context} if context else {}
        return (self.session.transcribe(audio, **kw).text or "").strip()

    def _reusable_preview(
        self,
        audio: np.ndarray,
        context_revision: int,
    ) -> tuple[str, str, int] | None:
        """Return (text, mode, unseen samples) when preview reuse is safe."""
        with self.lock:
            text = self._last_preview_text
            decoded_len = self._last_preview_len
            decoded_revision = self._last_preview_context_revision
            stable = self._last_preview_stable

        if text is None or decoded_revision != context_revision:
            return None
        if decoded_len > len(audio):
            return None

        unseen = len(audio) - decoded_len
        if unseen == 0:
            # Same samples + same context produces the same deterministic final
            # result, so a second pass would be pure duplicate work.
            return text, "reuse-exact", 0

        max_tail = int(MAX_SILENT_REUSE_TAIL * SAMPLE_RATE)
        tail = audio[decoded_len:]
        if unseen <= max_tail and stable and is_confident_silence(tail):
            return text, "reuse-silent-tail", unseen
        return None

    @staticmethod
    def _emit_final(
        text: str,
        secs: float,
        inference_ms: int,
        stop_started: float,
        mode: str,
        wait_ms: int,
        unseen_samples: int = 0,
    ) -> None:
        emit({
            "type": "final",
            "text": text,
            "secs": round(secs, 2),
            "ms": inference_ms,
            "total_ms": int((time.perf_counter() - stop_started) * 1000),
            "wait_ms": wait_ms,
            "mode": mode,
            "unseen_ms": int(unseen_samples / SAMPLE_RATE * 1000),
        })

    def _join_preview_thread(self, timeout: float | None = 5.0) -> bool:
        """Wait for preview inference without losing a still-live thread."""
        if self._thread is None:
            return True
        self._thread.join(timeout=timeout)
        if self._thread.is_alive():
            return False
        self._thread = None
        return True

    def _loop(self) -> None:
        last_len = 0
        while self.active:
            with self.lock:
                audio = self.buf.copy()
                context = self.context
                context_revision = self._context_revision
            grew = len(audio) - last_len >= int(MIN_NEW_AUDIO * SAMPLE_RATE)
            if len(audio) < int(MIN_SECONDS * SAMPLE_RATE) or not grew:
                time.sleep(POLL_INTERVAL)
                continue
            last_len = len(audio)
            try:
                text = self._decode(audio, context)
                stable = text == self._prev
                agreed = commonprefix(text, self._prev)
                if len(agreed) > len(self.committed):
                    self.committed = agreed
                self._prev = text
                with self.lock:
                    self._last_preview_text = text
                    self._last_preview_len = len(audio)
                    self._last_preview_context_revision = context_revision
                    self._last_preview_stable = stable
                if self.active:
                    emit({
                        "type": "partial",
                        "committed": self.committed,
                        "tail": text[len(self.committed):],
                    })
            except Exception as e:
                if self.active:
                    emit({"type": "error", "message": f"partial: {e}"})
            time.sleep(POLL_INTERVAL)

    # -- commands ------------------------------------------------------
    def start(self) -> None:
        # A fast final can reach Swift before its superseded preview pass has
        # finished cleaning up. A new start command is already ordered ahead of
        # its audio in the pipe, so wait here instead of rejecting the press:
        # once cleanup finishes, every queued audio packet is still consumed.
        if self._thread is not None and self._thread.is_alive():
            self.active = False
            self._join_preview_thread(timeout=None)
        with self.lock:
            self.buf = np.zeros(0, dtype=np.float32)
            self._last_preview_text = None
            self._last_preview_len = 0
            self._last_preview_context_revision = -1
            self._last_preview_stable = False
        self.committed = ""
        self._prev = ""
        self.active = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def audio(self, b64: str) -> None:
        pcm = np.frombuffer(base64.b64decode(b64), dtype=np.int16)
        chunk = pcm.astype(np.float32) / 32768.0
        with self.lock:
            self.buf = np.append(self.buf, chunk)
            cap = int(MAX_BUFFER_SEC * SAMPLE_RATE)
            if len(self.buf) > cap:
                self.buf = self.buf[-cap:]

    def set_context(self, text: str) -> None:
        """Update the vocabulary bias without reloading the model.

        The revision travels with every preview so a result decoded against an
        older context can never be reused as the final transcript.
        """
        with self.lock:
            if text != self.context:
                self.context = text
                self._context_revision += 1

    def stop(self) -> None:
        stop_started = time.perf_counter()
        self.active = False

        with self.lock:
            audio = self.buf.copy()
            context = self.context
            context_revision = self._context_revision
        secs = len(audio) / SAMPLE_RATE
        if secs < MIN_SECONDS:
            self._emit_final("", secs, 0, stop_started, "too-short", 0)
            self._join_preview_thread()
            return

        # Fastest path: a previously completed preview already contains the
        # whole utterance (or differs only by a short stable silence tail). Emit
        # before waiting for a newer, now-unneeded preview that may be in flight.
        reusable = self._reusable_preview(audio, context_revision)
        if reusable is not None:
            text, mode, unseen = reusable
            self._emit_final(text, secs, 0, stop_started, mode, 0, unseen)
            self._join_preview_thread()
            return

        wait_started = time.perf_counter()
        if not self._join_preview_thread():
            emit({"type": "error", "message": "final: preview decode did not stop"})
            return
        wait_ms = int((time.perf_counter() - wait_started) * 1000)

        # The in-flight preview may have completed on exactly the final buffer
        # while stop() was waiting. Reuse it before scheduling another pass.
        reusable = self._reusable_preview(audio, context_revision)
        if reusable is not None:
            text, mode, unseen = reusable
            self._emit_final(text, secs, 0, stop_started, mode, wait_ms, unseen)
            return

        inference_started = time.perf_counter()
        try:
            text = self._decode(audio, context)
        except Exception as e:
            emit({"type": "error", "message": f"final: {e}"})
            return
        inference_ms = int((time.perf_counter() - inference_started) * 1000)
        self._emit_final(
            text,
            secs,
            inference_ms,
            stop_started,
            "fresh-final",
            wait_ms,
        )


def main() -> int:
    model_id = os.environ.get("WHISPR_MODEL", "Qwen/Qwen3-ASR-0.6B")
    bits = int(os.environ.get("WHISPR_BITS", "8"))
    context = os.environ.get("WHISPR_CONTEXT", "")

    try:
        server = Server(model_id, bits, context)
    except Exception as e:
        emit({"type": "error", "message": f"load: {e}"})
        return 1

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = msg.get("cmd")
        try:
            if cmd == "start":
                server.start()
            elif cmd == "audio":
                server.audio(msg["pcm"])
            elif cmd == "stop":
                server.stop()
            elif cmd == "context":
                server.set_context(msg.get("text", ""))
            elif cmd == "quit":
                break
        except Exception as e:
            emit({"type": "error", "message": f"{cmd}: {e}"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
