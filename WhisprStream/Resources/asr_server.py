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
MAX_BUFFER_SEC = 45.0


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def commonprefix(a: str, b: str) -> str:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return a[:i]


class Server:
    def __init__(self, model_id: str, bits: int, context: str):
        self.context = context
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from asr_engine import build_session

        self.session, load_secs = build_session(model_id, bits)
        emit({"type": "ready", "ms": int(load_secs * 1000)})

        self.lock = threading.Lock()
        self.buf = np.zeros(0, dtype=np.float32)
        self.active = False
        self.committed = ""
        self._prev = ""
        self._thread: threading.Thread | None = None

    # -- transcription -------------------------------------------------
    def _decode(self, audio: np.ndarray) -> str:
        kw = {"context": self.context} if self.context else {}
        return (self.session.transcribe(audio, **kw).text or "").strip()

    def _loop(self) -> None:
        last_len = 0
        while self.active:
            with self.lock:
                audio = self.buf.copy()
            grew = len(audio) - last_len >= int(MIN_NEW_AUDIO * SAMPLE_RATE)
            if len(audio) < int(MIN_SECONDS * SAMPLE_RATE) or not grew:
                time.sleep(POLL_INTERVAL)
                continue
            last_len = len(audio)
            try:
                text = self._decode(audio)
                agreed = commonprefix(text, self._prev)
                if len(agreed) > len(self.committed):
                    self.committed = agreed
                self._prev = text
                if self.active:
                    emit({
                        "type": "partial",
                        "committed": self.committed,
                        "tail": text[len(self.committed):],
                    })
            except Exception as e:
                emit({"type": "error", "message": f"partial: {e}"})
            time.sleep(POLL_INTERVAL)

    # -- commands ------------------------------------------------------
    def start(self) -> None:
        with self.lock:
            self.buf = np.zeros(0, dtype=np.float32)
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

        A bare assignment is safe against the partial loop reading it mid-pass:
        the worst case is one pass using the previous string.
        """
        self.context = text

    def stop(self) -> None:
        self.active = False
        if self._thread is not None:
            self._thread.join(timeout=5.0)
            self._thread = None
        with self.lock:
            audio = self.buf.copy()
        secs = len(audio) / SAMPLE_RATE
        if secs < MIN_SECONDS:
            emit({"type": "final", "text": "", "secs": round(secs, 2), "ms": 0})
            return
        t = time.time()
        try:
            text = self._decode(audio)
        except Exception as e:
            emit({"type": "error", "message": f"final: {e}"})
            return
        emit({
            "type": "final",
            "text": text,
            "secs": round(secs, 2),
            "ms": int((time.time() - t) * 1000),
        })


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
