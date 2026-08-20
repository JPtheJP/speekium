"""Shared model loading for speekium.

8-bit quantization is the default because it measured 2.4x faster than fp16 on an
M1 Max with a byte-identical transcript. 4-bit is faster still by only ~6% but
degrades code-switching (`actually work不` -> `Actually Workable`), so it is not
the default. bits=0 selects fp16.
"""

from __future__ import annotations

import time

import numpy as np

SAMPLE_RATE = 16000


def build_session(model_id: str = "Qwen/Qwen3-ASR-0.6B", bits: int = 8, *, warm: bool = True):
    """Load, optionally quantize, and warm the ASR model. Returns (session, secs)."""
    t0 = time.time()
    from mlx_qwen3_asr import Session

    if bits and bits > 0:
        import mlx.core as mx
        from mlx_qwen3_asr import load_model
        from mlx_qwen3_asr.convert import quantize_model

        model, _cfg = load_model(model_id)
        model = quantize_model(model, bits=bits, group_size=64)
        mx.eval(model.parameters())
        session = Session(model=model, tokenizer_model=model_id)
    else:
        session = Session(model=model_id)

    if warm:
        # Force graph compilation now so the first real utterance isn't slow.
        session.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))

    return session, time.time() - t0
