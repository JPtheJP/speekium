#!/usr/bin/env python3
"""ASR sidecar for the Speekium macOS app.

Speaks newline-delimited JSON on stdin/stdout so Swift can drive it:

    in : {"cmd":"start"}
         {"cmd":"audio","pcm":"<base64 int16 mono 16k>"}
         {"cmd":"stop"}
    out: {"type":"ready","ms":850}
         {"type":"partial","committed":"...","tail":"..."}
         {"type":"final","text":"...","secs":2.6,"ms":140}
         {"type":"error","message":"..."}

Final passes re-decode the complete utterance (RTF ~0.024 at 8-bit), preserving
zh/en code-switching. Long live previews use a bounded recent window so they do
not compete with another full-length pass. LocalAgreement-2 marks a preview
prefix stable once two consecutive passes agree.
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
SHORT_UTTERANCE_MAX_SEC = 2.0
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
# Adaptive preview pacing deliberately creates idle decoder windows once an
# utterance grows beyond five seconds. A stable preview may remain reusable
# across that idle time, but only when every unseen frame is confidently
# silent. Speech-like audio always takes the authoritative final-decode path.
MAX_SILENT_REUSE_TAIL = 2.0
SILENCE_WINDOW_SEC = 0.02
SILENCE_MAX_WINDOW_RMS = 0.02
SILENCE_MAX_PEAK = 0.06

# Decoding mere elapsed audio lets a vocabulary prompt hallucinate one of its
# terms (for example "Claude") from room tone. Require several speech-level
# frames before the first preview or final pass. Three 20 ms frames reject a
# key click or isolated bump while adding at most 60 ms before live text starts.
SPEECH_MIN_WINDOW_RMS = 0.015
SPEECH_MIN_ACTIVE_WINDOWS = 3

PREVIEW_FULL_SPEED_SEC = 4.0
PREVIEW_ADAPTIVE_RAMP_SEC = 4.0
PREVIEW_COOLDOWN_DECODE_RATIO = 2.0
PREVIEW_MAX_COOLDOWN_SEC = 1.5

# Re-decoding a full 45-second buffer for every HUD update makes both the live
# text and the later final pass compete with multi-second preview work. Once an
# utterance exceeds this size, previews use only the recent window. The final
# decode still receives the complete buffer, so inserted text and code-switching
# accuracy are unchanged.
PREVIEW_MAX_AUDIO_SEC = 12.0
WINDOWED_PREVIEW_COOLDOWN_RATIO = 0.75
WINDOWED_PREVIEW_MAX_COOLDOWN_SEC = 0.4


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


def has_speech(audio: np.ndarray) -> bool:
    """Return True after enough speech-level frames, ignoring room tone/clicks."""
    window = max(1, int(SILENCE_WINDOW_SEC * SAMPLE_RATE))
    complete_frames = len(audio) // window
    if complete_frames < SPEECH_MIN_ACTIVE_WINDOWS:
        return False

    frames = audio[:complete_frames * window].reshape(complete_frames, window)
    rms = np.sqrt(np.mean(frames * frames, axis=1))
    return int(np.count_nonzero(rms >= SPEECH_MIN_WINDOW_RMS)) >= SPEECH_MIN_ACTIVE_WINDOWS


def preview_cooldown(
    audio_seconds: float,
    decode_seconds: float,
    *,
    windowed: bool = False,
) -> float:
    """Return an idle interval that keeps medium/long final decoding responsive.

    Short utterances retain the original live-preview cadence. From four
    seconds onward the idle interval ramps toward twice the duration of the
    previous preview pass, targeting roughly a 33% decoder duty cycle by eight
    seconds. This gives a stop command a useful chance to arrive while the
    model is idle, without changing the audio or authoritative final transcript.
    """
    if audio_seconds <= PREVIEW_FULL_SPEED_SEC or decode_seconds <= 0:
        return POLL_INTERVAL

    if windowed:
        adaptive = decode_seconds * WINDOWED_PREVIEW_COOLDOWN_RATIO
        return max(
            POLL_INTERVAL,
            min(WINDOWED_PREVIEW_MAX_COOLDOWN_SEC, adaptive),
        )

    progress = min(
        1.0,
        (audio_seconds - PREVIEW_FULL_SPEED_SEC) / PREVIEW_ADAPTIVE_RAMP_SEC,
    )
    adaptive = decode_seconds * PREVIEW_COOLDOWN_DECODE_RATIO * progress
    return max(POLL_INTERVAL, min(PREVIEW_MAX_COOLDOWN_SEC, adaptive))


def preview_audio(full_audio: np.ndarray) -> tuple[np.ndarray, int]:
    """Return the bounded HUD preview audio and its full-buffer start index."""
    preview_cap = int(PREVIEW_MAX_AUDIO_SEC * SAMPLE_RATE)
    preview_start = max(0, len(full_audio) - preview_cap)
    return full_audio[preview_start:], preview_start


SUPPORTED_SHORT_UTTERANCE_LANGUAGES = (
    "Chinese", "English", "Cantonese", "Arabic", "German", "French",
    "Spanish", "Portuguese", "Indonesian", "Italian", "Korean", "Russian",
    "Thai", "Vietnamese", "Japanese", "Turkish", "Hindi", "Malay", "Dutch",
    "Swedish", "Danish", "Finnish", "Polish", "Czech", "Filipino", "Persian",
    "Greek", "Hungarian", "Macedonian", "Romanian",
)


def normalize_short_utterance_language(value: str) -> str | None:
    """Return a canonical Qwen3-ASR forced-language name."""
    normalized = (value or "").strip().casefold()
    return next(
        (name for name in SUPPORTED_SHORT_UTTERANCE_LANGUAGES
         if name.casefold() == normalized),
        None,
    )


class Server:
    def __init__(
        self,
        model_id: str,
        bits: int,
        context: str,
        short_utterance_language: str = "English",
    ):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from asr_engine import build_session

        self.session, load_secs = build_session(model_id, bits)
        emit({"type": "ready", "ms": int(load_secs * 1000)})

        self.lock = threading.Lock()
        self.context = context
        self.short_utterance_language = normalize_short_utterance_language(
            short_utterance_language
        )
        self._utterance_short_language = self.short_utterance_language
        self._context_revision = 0
        self.buf = np.zeros(0, dtype=np.float32)
        self.active = False
        self.committed = ""
        self._prev = ""
        self._last_preview_text: str | None = None
        self._last_preview_len = 0
        self._last_preview_start = 0
        self._last_preview_context_revision = -1
        self._last_preview_language: str | None = None
        self._last_preview_stable = False
        self._thread: threading.Thread | None = None
        self._preview_stop = threading.Event()

    # -- transcription -------------------------------------------------
    def _language_for_audio(self, audio: np.ndarray) -> str | None:
        if len(audio) <= int(SHORT_UTTERANCE_MAX_SEC * SAMPLE_RATE):
            return self._utterance_short_language
        return None

    def _decode(
        self,
        audio: np.ndarray,
        context: str,
        language: str | None = None,
    ) -> str:
        kw = {"context": context} if context else {}
        if language:
            kw["language"] = language
        return (self.session.transcribe(audio, **kw).text or "").strip()

    def _decode_preview(self, audio: np.ndarray, context: str) -> str:
        """Decode live text without treating a sentence start as one word."""
        return self._decode(audio, context)

    def _decode_final(self, audio: np.ndarray, context: str) -> str:
        """Apply short-utterance guidance only after clip length is known."""
        return self._decode(audio, context, self._language_for_audio(audio))

    def _reusable_preview(
        self,
        audio: np.ndarray,
        context_revision: int,
    ) -> tuple[str, str, int] | None:
        """Return (text, mode, unseen samples) when preview reuse is safe."""
        with self.lock:
            text = self._last_preview_text
            decoded_len = self._last_preview_len
            decoded_start = self._last_preview_start
            decoded_revision = self._last_preview_context_revision
            decoded_language = self._last_preview_language
            stable = self._last_preview_stable

        if text is None or decoded_revision != context_revision:
            return None
        # A preview decoded while the short-clip preference applied must not be
        # reused if the final buffer has since crossed into automatic language
        # detection (or vice versa).
        if decoded_language != self._language_for_audio(audio):
            return None
        # A rolling-window preview intentionally contains only the recent HUD
        # text. It can never stand in for the full authoritative transcript.
        if decoded_start != 0:
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
                full_audio = self.buf.copy()
                context = self.context
                context_revision = self._context_revision
            full_len = len(full_audio)
            grew = full_len - last_len >= int(MIN_NEW_AUDIO * SAMPLE_RATE)
            if full_len < int(MIN_SECONDS * SAMPLE_RATE) or not grew:
                time.sleep(POLL_INTERVAL)
                continue
            last_len = full_len
            if not has_speech(full_audio):
                # Context terms are strong decoder hints, so never ask the
                # model to interpret audio that contains only room tone.
                continue
            audio, preview_start = preview_audio(full_audio)
            try:
                decode_started = time.perf_counter()
                text = self._decode_preview(audio, context)
                decode_seconds = time.perf_counter() - decode_started
                stable = text == self._prev
                agreed = commonprefix(text, self._prev)
                if preview_start == 0:
                    if len(agreed) > len(self.committed):
                        self.committed = agreed
                else:
                    # The rolling window moves forward, so its settled prefix
                    # may legitimately shrink. The HUD already truncates from
                    # the head and therefore naturally presents this recent
                    # full-context window as the visible tail of the utterance.
                    self.committed = agreed
                self._prev = text
                with self.lock:
                    self._last_preview_text = text
                    self._last_preview_len = full_len
                    self._last_preview_start = preview_start
                    self._last_preview_context_revision = context_revision
                    # Live previews always use automatic multilingual
                    # recognition. Only a completed short clip receives the
                    # user's one-word language guidance.
                    self._last_preview_language = None
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
                decode_seconds = 0.0

            cooldown = preview_cooldown(
                full_len / SAMPLE_RATE,
                decode_seconds,
                windowed=preview_start > 0,
            )
            # Unlike time.sleep(), Event.wait() lets stop() wake an idle
            # preview thread immediately instead of adding up to one second to
            # release latency at the long-utterance cap.
            if self._preview_stop.wait(timeout=cooldown):
                break

    # -- commands ------------------------------------------------------
    def start(self, short_utterance_language: str | None = None) -> None:
        # A fast final can reach Swift before its superseded preview pass has
        # finished cleaning up. A new start command is already ordered ahead of
        # its audio in the pipe, so wait here instead of rejecting the press:
        # once cleanup finishes, every queued audio packet is still consumed.
        if self._thread is not None and self._thread.is_alive():
            self.active = False
            self._preview_stop.set()
            self._join_preview_thread(timeout=None)
        with self.lock:
            self.buf = np.zeros(0, dtype=np.float32)
            self._last_preview_text = None
            self._last_preview_len = 0
            self._last_preview_start = 0
            self._last_preview_context_revision = -1
            self._last_preview_language = None
            self._last_preview_stable = False
        self.committed = ""
        self._prev = ""
        requested_language = normalize_short_utterance_language(
            short_utterance_language
        )
        self._utterance_short_language = (
            requested_language
            if short_utterance_language is not None
            else self.short_utterance_language
        )
        self._preview_stop.clear()
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
        self._preview_stop.set()

        with self.lock:
            audio = self.buf.copy()
            context = self.context
            context_revision = self._context_revision
        secs = len(audio) / SAMPLE_RATE
        if secs < MIN_SECONDS:
            self._emit_final("", secs, 0, stop_started, "too-short", 0)
            self._join_preview_thread()
            return

        if not has_speech(audio):
            self._emit_final("", secs, 0, stop_started, "no-speech", 0)
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
            text = self._decode_final(audio, context)
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
    model_id = os.environ.get("SPEEKIUM_MODEL", "Qwen/Qwen3-ASR-0.6B")
    bits = int(os.environ.get("SPEEKIUM_BITS", "8"))
    context = os.environ.get("SPEEKIUM_CONTEXT", "")
    short_utterance_language = os.environ.get(
        "SPEEKIUM_SHORT_UTTERANCE_LANGUAGE",
        "English",
    )

    try:
        server = Server(model_id, bits, context, short_utterance_language)
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
                server.start(msg.get("short_utterance_language"))
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
