#!/usr/bin/env python3
"""Live Voxtral streaming dictation with two fixes over stock voxmlx:

  1. Incremental UTF-8 detokenization  - stock decodes ONE token at a time, which
     corrupts multi-byte CJK characters into U+FFFD. We buffer token ids and emit
     only text that decodes cleanly.
  2. Optional --keep-context           - stock wipes the KV cache on every EOS
     (i.e. every natural pause), losing bilingual context.

Usage: live_stream.py [--keep-context] [--model PATH]
"""
import sys

import voxmlx.stream as vs

MODEL = "models/voxtral-6bit"
if "--model" in sys.argv:
    MODEL = sys.argv[sys.argv.index("--model") + 1]
keep_context = "--keep-context" in sys.argv

_orig_load = vs.load_model


def _patched_load(path):
    model, sp, config = _orig_load(path)

    class IncrementalTokenizer:
        """Buffers token ids so multi-byte characters are never split."""

        def __init__(self, inner):
            self._inner = inner
            self._pending = []
            self._emitted = ""

        def __getattr__(self, n):
            return getattr(self._inner, n)

        @property
        def eos_id(self):
            return -12345 if keep_context else self._inner.eos_id

        def decode(self, token_ids, **kw):
            self._pending.extend(token_ids)
            full = self._inner.decode(self._pending, **kw)
            # Hold back a trailing replacement char: its bytes are incomplete
            # and the next token will finish it.
            if full.endswith("�"):
                return ""
            delta = full[len(self._emitted):]
            self._emitted = full
            return delta

    return model, IncrementalTokenizer(sp), config


vs.load_model = _patched_load

print(f"model={MODEL}  keep_context={keep_context}")
try:
    vs.stream_transcribe(model_path=MODEL, temperature=0.0)
except KeyboardInterrupt:
    print("\n[stopped]")
