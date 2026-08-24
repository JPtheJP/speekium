"""Shared model loading behind a small engine-neutral transcription API.

Qwen3-ASR and Whisper use different MLX implementations and checkpoint
formats. The sidecar deliberately selects an adapter explicitly instead of
guessing from a repository name.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

import numpy as np

SAMPLE_RATE = 16000
SUPPORTED_ENGINES = ("qwen3", "whisper")


@dataclass(frozen=True)
class TranscriptionResult:
    text: str


# Whisper's tokenizer uses ISO-like language codes. The Settings UI keeps the
# existing human-readable Qwen names, so translate the shared subset here.
WHISPER_LANGUAGE_CODES = {
    "arabic": "ar",
    "cantonese": "zh",
    "chinese": "zh",
    "czech": "cs",
    "danish": "da",
    "dutch": "nl",
    "english": "en",
    "filipino": "tl",
    "finnish": "fi",
    "french": "fr",
    "german": "de",
    "greek": "el",
    "hindi": "hi",
    "hungarian": "hu",
    "indonesian": "id",
    "italian": "it",
    "japanese": "ja",
    "korean": "ko",
    "macedonian": "mk",
    "malay": "ms",
    "persian": "fa",
    "polish": "pl",
    "portuguese": "pt",
    "romanian": "ro",
    "russian": "ru",
    "spanish": "es",
    "swedish": "sv",
    "thai": "th",
    "turkish": "tr",
    "vietnamese": "vi",
}


class WhisperSession:
    """Expose mlx-whisper through the Session interface used by the sidecar."""

    def __init__(self, model_id: str):
        import mlx_whisper

        self._mlx_whisper = mlx_whisper
        self._model_id = model_id

    def transcribe(
        self,
        audio: np.ndarray,
        *,
        context: str = "",
        language: str | None = None,
    ) -> TranscriptionResult:
        options: dict[str, object] = {
            "path_or_hf_repo": self._model_id,
            # Any library progress text would corrupt the sidecar's JSON stdout.
            "verbose": None,
        }
        if context:
            options["initial_prompt"] = context
        if language:
            code = WHISPER_LANGUAGE_CODES.get(language.strip().casefold())
            if code:
                options["language"] = code
        result = self._mlx_whisper.transcribe(audio, **options)
        return TranscriptionResult(text=str(result.get("text") or ""))


def _qwen_session(model_id: str, bits: int):
    from mlx_qwen3_asr import Session

    if not bits or bits <= 0:
        return Session(model=model_id)

    import mlx.core as mx
    from mlx_qwen3_asr import load_model
    from mlx_qwen3_asr.convert import quantize_model

    model, _config = load_model(model_id)
    model = quantize_model(model, bits=bits, group_size=64)
    mx.eval(model.parameters())
    return Session(model=model, tokenizer_model=model_id)


def build_session(
    model_id: str = "Qwen/Qwen3-ASR-0.6B",
    bits: int = 8,
    *,
    engine: str = "qwen3",
    warm: bool = True,
):
    """Load and optionally warm one supported model. Returns (session, secs)."""
    if engine not in SUPPORTED_ENGINES:
        raise ValueError(f"unsupported speech engine: {engine}")

    started = time.time()
    if engine == "qwen3":
        session = _qwen_session(model_id, bits)
    else:
        # Whisper MLX repositories carry their own precision/quantization. The
        # Qwen runtime bit preference must not mutate those converted weights.
        session = WhisperSession(model_id)

    if warm:
        # Force graph compilation now so the first real utterance isn't slow.
        session.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))

    return session, time.time() - started
